"""PreToolUse guard for identity mode: GitHub writes only through as-role.sh, with the agent's own role.

Best effort, local only: the deterministic guarantees come from GitHub (token permissions and rulesets).
A no-op unless the project's .dev-loop.json configures "identities". Exit 2 refuses the tool call.
"""

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
    return cwd


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
    """Read the PreToolUse event and refuse what identity mode does not allow."""
    try:
        event = json.load(sys.stdin)
    except ValueError:
        return
    cwd = event.get("cwd") or os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
    config = load_config(cwd)
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
