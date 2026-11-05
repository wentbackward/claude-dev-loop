"""PreToolUse guard: the holdout scenario store stays hidden from the coding agents, and in identity mode
GitHub writes go only through as-role.sh, with the agent's own role.

Best effort, local only: the deterministic guarantees come from GitHub (token permissions and rulesets).
A no-op unless the project's .dev-loop.json turns scenarios on ("scenarios", or "factory": "dark") or
configures "identities". Exit 2 refuses the tool call. `guard-role.py --scenarios-dir [DIR]` prints the
store path as resolved from DIR (for tests).
"""

import glob
import json
import os
import re
import shlex
import subprocess
import sys

ROLES = {"implementer", "tester", "reviewer", "gate", "orchestrator"}
DEFAULT_AGENT_ROLES = {
    "": ["orchestrator"],
    "implementer": ["implementer"],
    "code-reviewer": ["reviewer"],
    "test-engineer": ["tester"],
    "verifier": ["tester"],
    "doc-auditor": ["tester"],
    "architect": ["tester"],
}
ROLE_OPERATIONS = {
    "implementer": {"push", "pr-write", "pr-comment", "api-write"},
    "tester": {"issue-write", "api-write"},
    "reviewer": {"review", "pr-comment", "api-write"},
    "orchestrator": {"issue-write", "pr-comment", "api-write"},
    "gate": set(),
}
WRAPPERS = {"env", "command", "exec", "time", "nohup", "sudo", "xargs"}
SEPARATORS = {";", "&&", "||", "|", "&", "\n", "(", ")", "|&"}
SCENARIO_BLIND = {"implementer", "test-engineer", "code-reviewer"}
GLOB_CHARS = set("*?[")


def refuse(reason: str) -> None:
    """Block the tool call and tell the agent why."""
    print(f"dev-loop guard: {reason}", file=sys.stderr)
    sys.exit(2)


def main_root(cwd: str) -> str:
    """The main worktree root of the repository that contains cwd, or empty."""
    try:
        common = subprocess.run(
            ["git", "-C", cwd, "rev-parse", "--path-format=absolute", "--git-common-dir"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return ""
    if os.path.basename(common) == ".git":
        return os.path.dirname(common)
    try:
        return subprocess.run(
            ["git", "-C", cwd, "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return ""


def load_config(cwd: str) -> dict:
    """The project config, or an empty dict."""
    path = os.environ.get("DEV_LOOP_CONFIG") or os.path.join(
        main_root(cwd) or cwd, ".dev-loop.json"
    )
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return {}


def scenarios_on(config: dict) -> bool:
    """True when scenarios are on, as dl_scenarios_setting in scripts/lib/scenarios.sh: an explicit
    "scenarios" key decides (null, false and "" are off), else "factory": "dark" turns them on."""
    if not isinstance(config, dict):
        return False
    if "scenarios" in config:
        value = config["scenarios"]
        return not (value is None or value is False or value == "")
    return config.get("factory") == "dark"


def scenarios_dir(config: dict, cwd: str) -> str:
    """The absolute store path, resolved exactly like dl_scenarios_dir in scripts/lib/scenarios.sh."""
    root = main_root(cwd)
    repo = os.path.basename(root or cwd)
    home = os.environ.get("HOME", "")
    state = f"{os.environ.get('DEV_LOOP_HOME') or home + '/.dev-loop'}/{repo}"
    block = config.get("scenarios")
    configured = block.get("dir") if isinstance(block, dict) else None
    if configured is not None and not isinstance(configured, str):
        configured = json.dumps(configured, separators=(",", ":"))
    if not configured:
        return f"{state}/scenarios"
    configured = configured.replace("<repo>", repo)
    if configured.startswith("/"):
        return configured
    if configured.startswith("~/"):
        return f"{home}/{configured[2:]}"
    return f"{root or cwd}/{configured}"


def store_forms(store: str) -> set[str]:
    """The store as written and with symlinks resolved, without a trailing slash."""
    return {os.path.normpath(store), os.path.realpath(store)}


def inside(path: str, forms: set[str]) -> bool:
    """True when path, as written or with symlinks resolved, is the store or below it."""
    for candidate in {os.path.normpath(path), os.path.realpath(path)}:
        if any(candidate == form or candidate.startswith(form.rstrip("/") + "/") for form in forms):
            return True
    return False


def expand(word: str, cwd: str) -> str:
    """A shell word as an absolute path: ~ and $VARS expanded, relative to cwd."""
    home = os.environ.get("HOME", "")
    if word == "~" or word.startswith("~/"):
        word = home + word[1:]
    return os.path.join(cwd, os.path.expandvars(word))


def touches_store(path: str, forms: set[str]) -> bool:
    """True when an absolute path, or a file its glob pattern matches, is inside the store."""
    if inside(path, forms):
        return True
    if GLOB_CHARS & set(path):
        return any(inside(match, forms) for match in glob.glob(path))
    return False


def word_candidates(word: str) -> list[str]:
    """The path-like parts of a shell word: itself, without a redirection, and after each =."""
    bare = re.sub(r"^[0-9]*[<>]+&?", "", word)
    return [bare] + [part for part in bare.split("=")[1:] if part]


def named_forms(forms: set[str]) -> list[str]:
    """The ways a command may spell the store: absolute, with ~ and with $HOME."""
    home = os.environ.get("HOME", "").rstrip("/")
    spelled = set(forms)
    for form in forms:
        if home and form.startswith(home + "/"):
            rest = form[len(home) :]
            spelled |= {"~" + rest, "$HOME" + rest, "${HOME}" + rest}
    return sorted(spelled)


def bash_touches_store(command: str, cwd: str, forms: set[str]) -> bool:
    """True when a shell command names the store (best effort: literal spellings, words, cd, globs)."""
    for spelled in named_forms(forms):
        if re.search(re.escape(spelled) + r"(?=$|[/\s'\"`;|&)])", command):
            return True
    for tokens in segments(command):
        if os.path.basename(tokens[0]) == "cd":
            cwd = expand(tokens[1], cwd) if len(tokens) > 1 else os.environ.get("HOME", cwd)
            continue
        for word in tokens:
            if any(touches_store(expand(part, cwd), forms) for part in word_candidates(word)):
                return True
    return False


def tool_touches_store(tool: str, tool_input: dict, cwd: str, forms: set[str]) -> bool:
    """True when a file tool (Read, Grep, Glob, Edit, Write, ...) would read or write the store."""
    base = expand(str(tool_input.get("path") or "."), cwd)
    paths = [base] if tool_input.get("path") else []
    if tool == "Glob" and tool_input.get("pattern"):
        paths.append(os.path.join(base, str(tool_input["pattern"])))
    paths += [expand(str(tool_input[key]), cwd) for key in ("file_path", "notebook_path") if tool_input.get(key)]
    return any(touches_store(path, forms) for path in paths)


def project_dir(cwd: str) -> str:
    """cwd when it is inside a git repository, else the session's project directory (CLAUDE_PROJECT_DIR)."""
    if main_root(cwd):
        return cwd
    return os.environ.get("CLAUDE_PROJECT_DIR") or cwd


def scenario_hit(event: dict, config: dict, cwd: str) -> bool:
    """True when the tool call names the scenario store of the project that cwd belongs to."""
    base = project_dir(cwd)
    if base != cwd:
        config = load_config(base)
    if not scenarios_on(config):
        return False
    forms = store_forms(scenarios_dir(config, base))
    tool, tool_input = event.get("tool_name", ""), event.get("tool_input", {}) or {}
    if tool == "Bash":
        return bash_touches_store(str(tool_input.get("command", "")), cwd, forms)
    return tool_touches_store(tool, tool_input, cwd, forms)


def check_scenarios(event: dict, config: dict, cwd: str) -> None:
    """Refuse a tool call by the implementer, test-engineer or code-reviewer that names the scenario store.

    Any error while checking (a NUL byte in a path, an odd event) refuses the call for these agents, so
    a crash can never let it through or skip the identity checks that follow.
    """
    agent = str(event.get("agent_type") or "").rsplit(":", 1)[-1]
    if agent not in SCENARIO_BLIND:
        return
    try:
        hit = scenario_hit(event, config, cwd)
    except Exception as error:  # fail closed for the blind agent types
        refuse(f"cannot check the tool call against the scenario store ({type(error).__name__}); refused")
    if hit:
        refuse(
            f"the holdout scenario store is off limits to the {agent} agent"
            " (scenarios are judged by the scenario-judge, never shown to the coding agents)"
        )


def secret_patterns(config: dict) -> list[str]:
    """Paths whose mention means an attempt to read role credentials."""
    patterns = [".config/dev-loop", "dev-loop-tokens", "DEV_LOOP_ROLE_TOKEN", ".pem"]
    for identity in config.get("identities", {}).values():
        if isinstance(identity, dict):
            for key in ("key_file", "token_file"):
                if identity.get(key):
                    patterns.append(os.path.basename(str(identity[key])))
    return patterns


def segments(command: str) -> list[list[str]]:
    """Split a shell command into simple commands (best effort); nested bash -c strings are expanded."""
    lexer = shlex.shlex(command, posix=True, punctuation_chars=";&|()\n")
    lexer.whitespace_split = True
    try:
        tokens = list(lexer)
    except ValueError:
        tokens = command.split()
    result: list[list[str]] = [[]]
    for token in tokens:
        if token in SEPARATORS:
            result.append([])
        else:
            result[-1].append(token)
    expanded: list[list[str]] = []
    for segment in result:
        segment = strip_prefix(segment)
        if (
            len(segment) >= 3
            and os.path.basename(segment[0]) in {"bash", "sh", "zsh"}
            and segment[1] == "-c"
        ):
            expanded.extend(segments(segment[2]))
        elif segment:
            expanded.append(segment)
    return expanded


def strip_prefix(segment: list[str]) -> list[str]:
    """Drop leading variable assignments and wrapper commands such as env or nohup."""
    index = 0
    while index < len(segment):
        token = segment[index]
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", token) or os.path.basename(token) in WRAPPERS or (
            token.startswith("-") and index > 0 and os.path.basename(segment[index - 1]) in WRAPPERS
        ):
            index += 1
        else:
            break
    return segment[index:]


def git_subcommand(tokens: list[str]) -> str:
    """The git subcommand after global options such as -C dir or -c key=value."""
    index = 1
    while index < len(tokens):
        token = tokens[index]
        if token in {"-C", "-c", "--git-dir", "--work-tree", "--namespace"}:
            index += 2
        elif token.startswith("-"):
            index += 1
        else:
            return token
    return ""


def classify(tokens: list[str]) -> str:
    """The kind of GitHub-side effect a simple command has ("read" when none)."""
    program = os.path.basename(tokens[0]) if tokens else ""
    if program == "git":
        return "push" if git_subcommand(tokens) == "push" else "read"
    if program in {"setup-identities.sh", "github-app-create.sh"}:
        return "admin"
    if program == "github-protect.sh":
        return "admin" if "--apply" in tokens else "read"
    if program != "gh" or len(tokens) < 2:
        return "read"
    group, action = tokens[1], tokens[2] if len(tokens) > 2 else ""
    if group == "pr":
        return {
            "create": "pr-write",
            "edit": "pr-write",
            "close": "pr-write",
            "reopen": "pr-write",
            "ready": "pr-write",
            "merge": "merge",
            "review": "review",
            "comment": "pr-comment",
        }.get(action, "read")
    if group == "issue":
        writes = {
            "create",
            "comment",
            "edit",
            "close",
            "reopen",
            "delete",
            "transfer",
            "lock",
            "unlock",
            "pin",
        }
        return "issue-write" if action in writes else "read"
    if group == "api":
        return "api-write" if api_writes(tokens) else "read"
    if group == "auth":
        return "read" if action == "status" else "secret"
    if group in {
        "release",
        "repo",
        "secret",
        "variable",
        "ruleset",
        "workflow",
        "label",
        "gpg-key",
        "ssh-key",
    }:
        return "read" if action in {"list", "view", "status", ""} else "admin"
    return "read"


def api_writes(tokens: list[str]) -> bool:
    """True when a gh api call sends a write method or a request body."""
    for index, token in enumerate(tokens):
        if token in {"-X", "--method"} and index + 1 < len(tokens):
            if tokens[index + 1].upper() != "GET":
                return True
        if re.match(r"^(-X|--method=)(POST|PUT|PATCH|DELETE)$", token, re.IGNORECASE):
            return True
        if token in {"-f", "-F", "--field", "--raw-field", "--input"} or token.startswith(
            ("--field=", "--raw-field=")
        ):
            return True
    return False


def agent_roles(config: dict, agent_type: str) -> list[str]:
    """The roles an agent may act as (plugin prefixes such as dev-loop: are ignored)."""
    name = agent_type.rsplit(":", 1)[-1]
    overrides = config.get("guard", {}).get("agents", {})
    if name in overrides:
        return list(overrides[name])
    return DEFAULT_AGENT_ROLES.get(name, [])


def check_segment(tokens: list[str], roles: list[str], who: str) -> None:
    """Refuse a simple command that writes to GitHub without the agent's role."""
    if os.path.basename(tokens[0]) == "as-role.sh":
        role = tokens[1] if len(tokens) > 1 else ""
        rest = strip_prefix(tokens[2:])
        if role not in ROLES:
            refuse(f"unknown role '{role}'")
        if role == "gate":
            refuse(
                "the gate identity is used only by gate-train.sh and merge-train.sh, never directly"
            )
        if role not in roles:
            refuse(f"{who} may act only as {', '.join(roles) or 'no role'}, not as {role}")
        operation = classify(rest) if rest else "read"
        if operation in {"merge", "admin", "secret"}:
            refuse(
                f"'{' '.join(rest[:3])}' is not allowed for agents (merges go through merge-train.sh)"
            )
        if operation != "read" and operation not in ROLE_OPERATIONS[role]:
            refuse(f"the {role} role may not '{' '.join(rest[:3])}'")
        return
    operation = classify(tokens)
    if operation == "read":
        return
    if operation in {"merge", "admin", "secret"}:
        refuse(
            f"'{' '.join(tokens[:3])}' is not allowed for agents (merges go through merge-train.sh;"
            " repository settings and credentials are for the owner)"
        )
    allowed = [role for role in roles if operation in ROLE_OPERATIONS[role]]
    command = " ".join(tokens[:3])
    if not allowed:
        owners = sorted(role for role, operations in ROLE_OPERATIONS.items() if operation in operations)
        refuse(f"{who} may not '{command}' (it is the job of: {', '.join(owners)})")
    refuse(f"'{command}' writes to GitHub: run it as `as-role.sh {allowed[0]} {command} ...`")


def tool_paths(tool_input: dict) -> list[str]:
    """Paths a file tool would touch."""
    return [
        str(tool_input[key])
        for key in ("file_path", "path", "pattern", "notebook_path")
        if key in tool_input
    ]


def main() -> None:
    """Read the PreToolUse event and refuse what the scenario store and identity mode do not allow."""
    if sys.argv[1:2] == ["--scenarios-dir"]:
        cwd = sys.argv[2] if len(sys.argv) > 2 else os.getcwd()
        print(scenarios_dir(load_config(cwd), cwd))
        return
    try:
        event = json.load(sys.stdin)
    except ValueError:
        return
    cwd = event.get("cwd") or os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
    config = load_config(cwd)
    check_scenarios(event, config, cwd)
    identities = config.get("identities")
    if not isinstance(identities, dict) or not any(
        isinstance(v, dict) and v.get("type") for v in identities.values()
    ):
        return
    tool, tool_input = event.get("tool_name", ""), event.get("tool_input", {}) or {}
    patterns = secret_patterns(config)
    if tool != "Bash":
        for path in tool_paths(tool_input):
            if any(pattern in path for pattern in patterns):
                refuse("role credentials are off limits to agents")
        return
    command = str(tool_input.get("command", ""))
    if any(pattern in command for pattern in patterns):
        refuse("role credentials are off limits to agents")
    agent_type = event.get("agent_type") or ""
    roles = agent_roles(config, agent_type)
    who = f"agent {agent_type}" if agent_type else "the main session"
    for tokens in segments(command):
        check_segment(tokens, roles, who)


if __name__ == "__main__":
    main()
