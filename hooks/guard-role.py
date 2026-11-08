"""PreToolUse guard: git commands that a stop condition forbids are refused, the holdout scenario store
stays hidden from the coding agents, and in identity mode GitHub writes go only through as-role.sh, with
the agent's own role.

Best effort, local only: the deterministic guarantees come from GitHub (token permissions and rulesets).
A no-op without .dev-loop.json. The git check runs in every loop project unless "guard": false; the
scenario check only when scenarios are on ("scenarios", or "factory": "dark"); the GitHub checks only when
"identities" is configured. Exit 2 refuses the tool call. `--git-only` runs only the git check (guard-role.sh
passes it when the project has neither scenarios nor identities). `guard-role.py --scenarios-dir [DIR]` prints the
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
# Wrapper commands that run the command after them, each with its options that take a separate value.
WRAPPERS = {
    "env": {"-u", "--unset", "-C", "--chdir", "-S", "--split-string"},
    "command": set(),
    "exec": {"-a"},
    "time": {"-f", "--format", "-o", "--output"},
    "nohup": set(),
    "nice": {"-n", "--adjustment"},
    "timeout": {"-s", "--signal", "-k", "--kill-after"},
    "stdbuf": {"-i", "--input", "-o", "--output", "-e", "--error"},
    "sudo": {"-u", "--user", "-g", "--group", "-C", "--close-from", "-D", "--chdir", "-h", "--host", "-p",
             "--prompt", "-U", "--other-user", "-r", "--role", "-t", "--type", "-T", "--command-timeout"},
    "xargs": {"-a", "--arg-file", "-d", "--delimiter", "-E", "-e", "-I", "-i", "-L", "-l", "-n", "--max-args",
              "-P", "--max-procs", "-s", "--max-chars"},
}
RESERVED = {"{", "}", "!", "if", "then", "else", "elif", "do", "while", "until"}
SHELLS = {"bash", "sh", "zsh", "dash", "ksh"}
SEPARATOR_CHARS = set(";&|()\n")
SCENARIO_BLIND = {"implementer", "test-engineer", "code-reviewer"}
GLOB_CHARS = set("*?[")


class Unparsable(Exception):
    """A command that names git but that the guard cannot split as bash would (an unbalanced quote)."""


def text_names_git(text: str) -> bool:
    """True when text has "git" once quotes, backslashes and line continuations are removed."""
    return "git" in re.sub(r"[\\'\"]", "", text.replace("\\\n", ""))


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


def config_path(cwd: str) -> str:
    """The project config file for cwd: DEV_LOOP_CONFIG, else .dev-loop.json in the main worktree."""
    return os.environ.get("DEV_LOOP_CONFIG") or os.path.join(main_root(cwd) or cwd, ".dev-loop.json")


def load_config(cwd: str) -> dict:
    """The project config, or an empty dict."""
    try:
        with open(config_path(cwd), encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return {}


def scenarios_on(config: dict) -> bool:
    """True when scenarios are on, as dl_scenarios_setting in scripts/lib/scenarios.sh: an explicit
    "scenarios" key decides (null, false, "" and the string "false", which cfg prints alike, are off),
    else "factory": "dark" turns them on."""
    if not isinstance(config, dict):
        return False
    if "scenarios" in config:
        value = config["scenarios"]
        return not (value is None or value is False or value in ("", "false"))
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


def heredoc_word(command: str, index: int) -> tuple[bool, bool, str, int] | None:
    """The here-document after a `<<` that ends before index: (strip tabs, delimiter quoted, delimiter, the
    index after it), or None when no delimiter word follows."""
    dash = command.startswith("-", index)
    index += 1 if dash else 0
    while index < len(command) and command[index] in " \t":
        index += 1
    start = index
    while index < len(command) and command[index] not in " \t\n;&|()<>":
        if command[index] in "'\"":
            close = command.find(command[index], index + 1)
            index = len(command) if close < 0 else close + 1
        else:
            index += 2 if command[index] == "\\" else 1
    word = command[start:index]
    if not word:
        return None
    try:
        delimiter = "".join(shlex.split(word))
    except ValueError:
        return None
    return dash, any(char in word for char in "'\"\\"), delimiter, index


def take_bodies(command: str, index: int, pending: list[tuple[bool, bool, str]]) -> tuple[int, list[str]] | None:
    """Skip the bodies of the pending here-documents from index: (the index after the last end word, the
    command substitutions of the unquoted bodies), or None when an end word never comes."""
    found: list[str] = []
    for dash, quoted, word in pending:
        while True:
            if index > len(command):
                return None
            end = command.find("\n", index)
            end = len(command) if end < 0 else end
            line = command[index:end]
            index = end + 1
            if (line.lstrip("\t") if dash else line) == word:
                break
            if not quoted:
                found += substitutions(line, heredoc=True)
    return min(index - 1, len(command)), found


def arithmetic_end(command: str, index: int) -> int:
    """The index after the (( )) that starts at index (the end of the command when it never closes)."""
    depth = 0
    while index < len(command):
        depth += {"(": 1, ")": -1}.get(command[index], 0)
        index += 1
        if depth == 0:
            return index
    return index


def ansi_c_end(command: str, index: int) -> int:
    """The index after the $'...' string that starts at index, or -1 when it never closes (a backslash
    escapes the next character inside it)."""
    index += 2
    while index < len(command):
        if command[index] == "\\":
            index += 2
        elif command[index] == "'":
            return index + 1
        else:
            index += 1
    return -1


def ansi_c_quoted(body: str) -> str:
    """A $'...' body as a plain single-quoted word: escaped quotes and backslashes taken literally, other
    escapes kept as written (they only change text, never where the word ends)."""
    text = re.sub(r"\\([\\'\"])", r"\1", body)
    return "'" + text.replace("'", "'\"'\"'") + "'"


def strip_heredocs(command: str) -> str:
    """The command without its comments and the bodies of its here-documents (text, not run).

    A here-document starts only at an unquoted `<<` outside comments and arithmetic, so a quoted or
    commented `<<WORD` hides nothing; an ANSI-C string ($'...') becomes a plain single-quoted word; the
    command substitutions of an unquoted body (which the shell runs) are kept as lines of their own; a
    body whose end word never comes is kept as commands.
    """
    out: list[str] = []
    extra: list[str] = []
    pending: list[tuple[bool, bool, str]] = []
    stack: list[list] = []  # one [quote outside, open parentheses] per $( ) entered
    quote, index = "", 0
    while index < len(command):
        char = command[index]
        step = 1
        if quote == "'":
            quote = "" if char == "'" else quote
        elif char == "\\":
            step = 2
        elif quote == '"' and char == '"':
            quote = ""
        elif command.startswith("$((", index) or (not quote and command.startswith("((", index)):
            step = arithmetic_end(command, index + (1 if char == "$" else 0)) - index
        elif command.startswith("$(", index):
            stack.append([quote, 0])
            quote, step = "", 2
        elif quote:
            pass
        elif command.startswith("$'", index) and ansi_c_end(command, index) > 0:
            end = ansi_c_end(command, index)
            out.append(ansi_c_quoted(command[index + 2 : end - 1]))
            index = end
            continue
        elif char in "'\"":
            quote = char
        elif char == "(" and stack:
            stack[-1][1] += 1
        elif char == ")" and stack:
            if stack[-1][1]:
                stack[-1][1] -= 1
            else:
                quote = stack.pop()[0]
        elif char == "#" and (index == 0 or command[index - 1] in " \t\n;&|()"):
            end = command.find("\n", index)
            index = len(command) if end < 0 else end
            continue
        elif command.startswith("<<<", index):
            step = 3
        elif command.startswith("<<", index):
            parsed = heredoc_word(command, index + 2)
            if parsed:
                pending.append(parsed[:3])
                step = parsed[3] - index
            else:
                step = 2
        elif char == "\n" and pending:
            bodies = take_bodies(command, index + 1, pending)
            pending = []
            if bodies:
                out.append("\n")
                index, found = bodies
                extra += found
                continue
        out.append(command[index : index + step])
        index += step
    return "\n".join(["".join(out)] + extra)


def substitutions(command: str, heredoc: bool = False) -> list[str]:
    """The commands inside backticks, and inside $( ) within double quotes or a here-document body (the
    lexer splits the others)."""
    found, index, quote = [], 0, '"' if heredoc else ""
    while index < len(command):
        char = command[index]
        if heredoc and char in "'\"":
            pass
        elif quote == "'":
            quote = "" if char == "'" else quote
        elif char == "\\":
            index += 1
        elif char == "'" and not quote:
            quote = "'"
        elif char == '"':
            quote = "" if quote else '"'
        elif char == "`":
            end = command.find("`", index + 1)
            end = len(command) if end < 0 else end
            found.append(command[index + 1 : end])
            index = end
        elif char == "$" and command[index + 1 : index + 2] == "(" and quote:
            depth, end = 0, index + 1
            while end < len(command):
                depth += {"(": 1, ")": -1}.get(command[end], 0)
                if depth == 0:
                    break
                end += 1
            found.append(command[index + 2 : end])
            index = end
        index += 1
    return found


def inner_command(segment: list[str]) -> str | None:
    """The command string a shell (bash -c, -lc, ...) or eval runs, or None."""
    program = os.path.basename(segment[0])
    if program == "eval":
        return " ".join(segment[1:])
    if program not in SHELLS:
        return None
    for index, token in enumerate(segment[1:], start=1):
        if not token.startswith("-") or token.startswith("--"):
            return None
        if "c" in token[1:]:
            return segment[index + 1] if index + 1 < len(segment) else ""
    return None


def segments(command: str) -> list[list[str]]:
    """Split a shell command into simple commands (best effort): here-document bodies dropped, nested
    bash -c and eval strings and command substitutions expanded. Raises Unparsable when a command that
    names git cannot be split (a quote read differently from bash would hide every later command)."""
    command = strip_heredocs(command.replace("\\\n", ""))
    lexer = shlex.shlex(command, posix=True, punctuation_chars=";&|()\n")
    lexer.whitespace = " \t\r"
    lexer.commenters = ""
    lexer.whitespace_split = True
    try:
        tokens = list(lexer)
    except ValueError:
        if text_names_git(command):
            raise Unparsable(command) from None
        tokens = command.split()
    result: list[list[str]] = [[]]
    for token in tokens:
        if token and set(token) <= SEPARATOR_CHARS:
            result.append([])
        else:
            result[-1].append(token)
    expanded: list[list[str]] = []
    for segment in result:
        segment = strip_prefix(segment)
        inner = inner_command(segment) if segment else None
        if inner is not None:
            expanded.extend(segments(inner))
        elif segment:
            expanded.append(segment)
    for inner in substitutions(command):
        expanded.extend(segments(inner))
    return expanded


def strip_prefix(segment: list[str]) -> list[str]:
    """Drop leading variable assignments, reserved words (if, then, !, {, ...) and wrapper commands such as
    env, nice, timeout or nohup with their own options and values."""
    index = 0
    while index < len(segment):
        token = segment[index]
        wrapper = os.path.basename(token)
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", token) or token in RESERVED:
            index += 1
        elif wrapper in WRAPPERS:
            split = env_split_string(segment, index + 1) if wrapper == "env" else None
            if split is not None:
                segment, index = split, 0
            else:
                index = skip_wrapper_options(segment, index + 1, wrapper)
        else:
            break
    return segment[index:]


def env_split_string(segment: list[str], index: int) -> list[str] | None:
    """For env -S/--split-string STRING ARGS: the words of STRING followed by ARGS (what env runs), or None
    when the env options at index have no split string."""
    while index < len(segment) and segment[index].startswith("-") and segment[index] not in {"-", "--"}:
        token = segment[index]
        value, rest = None, index + 1
        if token in {"-S", "--split-string"}:
            value, rest = (segment[index + 1] if index + 1 < len(segment) else ""), index + 2
        elif token.startswith("--split-string="):
            value = token.split("=", 1)[1]
        elif token.startswith("-S"):
            value = token[2:]
        if value is not None:
            try:
                words = shlex.split(value)
            except ValueError:
                if text_names_git(" ".join([value] + segment[rest:])):
                    raise Unparsable(value) from None
                words = value.split()
            return words + segment[rest:]
        index += 2 if token in WRAPPERS["env"] else 1
    return None


def skip_wrapper_options(segment: list[str], index: int, wrapper: str) -> int:
    """The index after a wrapper's options (and timeout's duration)."""
    while index < len(segment) and segment[index].startswith("-") and segment[index] != "-":
        token = segment[index]
        index += 1
        if token == "--":
            break
        if token in WRAPPERS[wrapper]:
            index += 1
    if wrapper == "timeout" and index < len(segment) and re.match(r"^[0-9.]+[smhd]?$", segment[index]):
        index += 1
    return index


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
    block = config.get("guard")
    overrides = block.get("agents", {}) if isinstance(block, dict) else {}
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


# Git stop conditions: the options the guarded subcommands accept that matter for parsing, as
# {long name: "none" | "value" | "optional"}, and their short forms as {letter: long name}. Every dangerous
# option is listed, so any abbreviation of one resolves to it; an option not listed is taken as written.
GIT_LONG = {
    "fetch": {
        "upload-pack": "value", "all": "none", "append": "none", "atomic": "none", "depth": "value",
        "deepen": "value", "shallow-since": "value", "shallow-exclude": "value", "unshallow": "none",
        "update-shallow": "none", "update-head-ok": "none", "force": "none", "keep": "none",
        "multiple": "none", "prune": "none", "prune-tags": "none", "tags": "none", "no-tags": "none",
        "jobs": "value", "quiet": "none", "verbose": "none", "progress": "none", "server-option": "value",
        "refmap": "value", "recurse-submodules": "optional", "dry-run": "none", "write-fetch-head": "none",
        "ipv4": "none", "ipv6": "none", "set-upstream": "none", "filter": "value", "negotiation-tip": "value",
    },
    "pull": {
        "upload-pack": "value", "rebase": "optional", "ff-only": "none", "ff": "none", "squash": "none",
        "commit": "none", "edit": "none", "autostash": "none", "strategy": "value",
        "strategy-option": "value", "quiet": "none", "verbose": "none", "all": "none", "tags": "none",
        "depth": "value", "unshallow": "none", "prune": "none", "jobs": "value", "force": "none",
        "signoff": "none", "stat": "none", "verify": "none", "set-upstream": "none",
    },
    "rebase": {
        "exec": "value", "onto": "value", "keep-base": "none", "root": "none", "continue": "none",
        "abort": "none", "skip": "none", "quit": "none", "edit-todo": "none", "show-current-patch": "none",
        "apply": "none", "merge": "none", "interactive": "none", "rebase-merges": "optional",
        "strategy": "value", "strategy-option": "value", "gpg-sign": "optional", "empty": "value",
        "keep-empty": "none", "autosquash": "none", "autostash": "none", "update-refs": "none",
        "fork-point": "none", "force-rebase": "none", "ff": "none", "quiet": "none", "verbose": "none",
        "stat": "none", "signoff": "none", "verify": "none", "whitespace": "value", "trailer": "value",
        "committer-date-is-author-date": "none", "ignore-date": "none", "reset-author-date": "none",
        "ignore-whitespace": "none", "reschedule-failed-exec": "none", "rerere-autoupdate": "none",
        "allow-empty-message": "none", "context": "value",
    },
    "diff": {"output": "value", "output-indicator-new": "value", "output-indicator-old": "value",
             "output-indicator-context": "value"},
    "worktree remove": {"force": "none"},
    "push": {
        "receive-pack": "value", "exec": "value", "repo": "value", "all": "none", "branches": "none",
        "mirror": "none", "delete": "none", "tags": "none", "follow-tags": "none", "force": "none",
        "force-with-lease": "optional", "force-if-includes": "none", "prune": "none", "set-upstream": "none",
        "push-option": "value", "dry-run": "none", "porcelain": "none", "atomic": "none", "signed": "optional",
        "thin": "none", "quiet": "none", "verbose": "none", "progress": "none", "verify": "none",
        "recurse-submodules": "value", "ipv4": "none", "ipv6": "none",
    },
}
GIT_LONG["log"] = GIT_LONG["show"] = GIT_LONG["diff"]
GIT_SHORT = {
    "fetch": {"a": "append", "f": "force", "j": "jobs", "k": "keep", "m": "multiple", "o": "server-option",
              "p": "prune", "P": "prune-tags", "q": "quiet", "t": "tags", "u": "update-head-ok", "v": "verbose"},
    "pull": {"q": "quiet", "v": "verbose", "f": "force", "j": "jobs", "r": "rebase", "s": "strategy",
             "X": "strategy-option", "n": "stat"},
    "rebase": {"x": "exec", "i": "interactive", "m": "merge", "r": "rebase-merges", "s": "strategy",
               "X": "strategy-option", "S": "gpg-sign", "k": "keep-empty", "f": "force-rebase", "q": "quiet",
               "v": "verbose", "n": "stat", "C": "context"},
    "diff": {}, "log": {}, "show": {},
    "worktree remove": {"f": "force"},
    "push": {"d": "delete", "f": "force", "n": "dry-run", "o": "push-option", "q": "quiet", "u": "set-upstream",
             "v": "verbose"},
}
GIT_DANGER = {
    "fetch": {"upload-pack": "runs a command of its own (--upload-pack)"},
    "pull": {"upload-pack": "runs a command of its own (--upload-pack)"},
    "rebase": {"exec": "runs a command after each commit (--exec/-x)"},
    "diff": {"output": "writes a file anywhere (--output)"},
    "log": {"output": "writes a file anywhere (--output)"},
    "show": {"output": "writes a file anywhere (--output)"},
    "worktree remove": {"force": "drops uncommitted work (worktree remove --force)"},
    "push": {
        "receive-pack": "runs a command of its own (--receive-pack)",
        "exec": "runs a command of its own (--exec)",
        "all": "pushes every branch, the base included (--all)",
        "branches": "pushes every branch, the base included (--branches)",
        "mirror": "mirrors every ref, the base and tags included (--mirror)",
        "delete": "deletes a remote branch (--delete/-d)",
        "prune": "deletes remote branches (--prune)",
        "tags": "pushes tags (--tags)",
        "follow-tags": "pushes tags (--follow-tags)",
        "force": "force-pushes (--force/-f)",
        "force-with-lease": "force-pushes (--force-with-lease)",
        "force-if-includes": "force-pushes (--force-if-includes)",
    },
}
GIT_GLOBAL_VALUE = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--config-env", "--exec-path",
                    "--super-prefix", "--list-cmds", "--attr-source"}
REBASE_ACTIONS = {"continue", "abort", "skip", "quit", "edit-todo", "show-current-patch"}


def guard_on(config: dict) -> bool:
    """The git check is on unless the project's config says "guard": false."""
    return config.get("guard") is not False


def git_refuse(command: str, why: str) -> None:
    """Refuse a git command that a stop condition forbids."""
    refuse(f"'{command}' is refused: it {why}, which is a stop condition; ask the owner to run it")


def git_split(tokens: list[str], cwd: str) -> tuple[str, list[str], str, bool]:
    """(subcommand, its arguments, the directory git runs in, whether config is injected with -c)."""
    index, injected = 1, False
    while index < len(tokens):
        token = tokens[index]
        name = token.split("=", 1)[0]
        if token in GIT_GLOBAL_VALUE:
            value = tokens[index + 1] if index + 1 < len(tokens) else ""
            if token == "-C":
                cwd = expand(value, cwd)
            injected = injected or token in {"-c", "--config-env"}
            index += 2
        elif token.startswith("-"):
            injected = injected or name == "--config-env"
            index += 1
        else:
            break
    if index >= len(tokens):
        return "", [], cwd, injected
    sub, rest = tokens[index], tokens[index + 1 :]
    if sub == "worktree" and rest[:1] == ["remove"]:
        sub, rest = "worktree remove", rest[1:]
    return sub, rest, cwd, injected


def resolve_long(sub: str, name: str) -> set[str]:
    """The options a long option name (maybe an abbreviation) may mean: itself when listed, else every
    listed option it is a prefix of; a --no- negation means none (they only turn things off)."""
    options = GIT_LONG[sub]
    if name in options:
        return {name}
    if name.startswith("no-"):
        return set()
    return {option for option in options if option.startswith(name)} or {name}


def git_parse(sub: str, args: list[str]) -> tuple[list[tuple[str, str]], list[str]]:
    """The options as (long name, value) pairs, every meaning of an abbreviation and every letter of a
    bundle expanded, and the positional arguments."""
    options: list[tuple[str, str]] = []
    positional: list[str] = []
    index = 0
    while index < len(args):
        token = args[index]
        index += 1
        if token in {"--", "--end-of-options"}:
            positional += args[index:]
            break
        if token.startswith("--"):
            name, eq, value = token[2:].partition("=")
            meanings = resolve_long(sub, name)
            if not eq and index < len(args) and any(GIT_LONG[sub].get(o) == "value" for o in meanings):
                value = args[index]
                index += 1
            options += [(option, value) for option in meanings]
        elif token.startswith("-") and len(token) > 1:
            letters = token[1:]
            while letters:
                option = GIT_SHORT[sub].get(letters[0], letters[0])
                letters = letters[1:]
                kind = GIT_LONG[sub].get(option, "none")
                if kind in {"value", "optional"} and letters:
                    options.append((option, letters))
                    letters = ""
                elif kind == "value":
                    options.append((option, args[index] if index < len(args) else ""))
                    index += 1
                else:
                    options.append((option, ""))
        else:
            positional.append(token)
    return options, positional


def current_branch(cwd: str) -> str:
    """The branch checked out in cwd ("HEAD" when detached), or empty outside a repository."""
    try:
        return subprocess.run(
            ["git", "-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return ""


def is_tag(name: str, cwd: str) -> bool:
    """True when name is a tag and not a branch of the repository in cwd."""

    def exists(ref: str) -> bool:
        try:
            return subprocess.run(["git", "-C", cwd, "show-ref", "--verify", "--quiet", ref]).returncode == 0
        except OSError:
            return False

    return exists(f"refs/tags/{name}") and not exists(f"refs/heads/{name}")


def names_base(ref: str, base: str) -> bool:
    """True when a ref as written in a refspec names the base branch."""
    return ref in {base, f"heads/{base}", f"refs/heads/{base}"}


def head_branch(ref: str, cwd: str, command: str) -> str:
    """A ref with HEAD (or @) replaced by the branch checked out in cwd; refuses when it cannot tell."""
    if ref not in {"HEAD", "@"}:
        return ref
    branch = current_branch(cwd)
    if not branch:
        git_refuse(command, f"pushes HEAD from {cwd}, a directory the guard cannot read, so maybe the base branch")
    return branch


def check_push(options: list[tuple[str, str]], positional: list[str], cwd: str, base: str, command: str) -> None:
    """Refuse a push that forces, deletes or tags, or whose source or destination is the base branch."""
    repo_given = any(option == "repo" for option, _ in options)
    refspecs = positional if repo_given else positional[1:]
    for spec in refspecs or ["HEAD"]:
        if spec.startswith("+"):
            git_refuse(command, f"force-pushes ({spec})")
        if GLOB_CHARS & set(spec):
            git_refuse(command, f"pushes every ref a pattern matches, the base branch maybe included ({spec})")
        source, colon, destination = spec.partition(":")
        if colon and not source:
            git_refuse(command, f"deletes a remote branch ({spec})")
        source = head_branch(source, cwd, command)
        destination = destination if colon else source
        for ref in (source, destination):
            if ref.startswith(("refs/tags/", "tags/")) or (ref == source and is_tag(ref, cwd)):
                git_refuse(command, f"pushes a tag ({spec})")
            if names_base(ref, base):
                git_refuse(command, f"pushes the base branch {base} ({spec})")


def check_rebase(options: list[tuple[str, str]], positional: list[str], cwd: str, base: str, command: str) -> None:
    """Refuse a rebase whose rewritten branch is the base branch."""
    names = {option for option, _ in options}
    if names & REBASE_ACTIONS:
        return
    wanted = 0 if "root" in names else 1
    branch = positional[wanted] if len(positional) > wanted else "HEAD"
    if branch in {"HEAD", "@"}:
        branch = current_branch(cwd)
    if names_base(branch, base):
        git_refuse(command, f"rewrites the base branch {base}")


def check_git(tokens: list[str], cwd: str, base: str) -> None:
    """Refuse a git command whose parsed argv hits a stop condition."""
    sub, args, cwd, injected = git_split(tokens, cwd)
    command = " ".join(tokens)
    if injected:
        git_refuse(command, "injects git config (-c/--config-env), which can run a command (aliases, pagers, ssh)")
    if sub not in GIT_LONG:
        return
    options, positional = git_parse(sub, args)
    for option, _ in options:
        if option in GIT_DANGER.get(sub, {}):
            git_refuse(command, GIT_DANGER[sub][option])
    if sub == "push":
        check_push(options, positional, cwd, base, command)
    elif sub == "rebase":
        check_rebase(options, positional, cwd, base, command)


def git_commands(command: str, cwd: str) -> list[tuple[list[str], str]]:
    """The git commands in a shell command with the directory each runs in (cd followed; as-role.sh and
    heavy.sh unwrapped)."""
    found = []
    for tokens in parsed_segments(command):
        program = os.path.basename(tokens[0])
        if program == "cd":
            cwd = expand(tokens[1], cwd) if len(tokens) > 1 else os.environ.get("HOME", cwd)
            continue
        if program == "as-role.sh":
            tokens = strip_prefix(tokens[2:])
        elif program == "heavy.sh":
            tokens = strip_prefix(tokens[1:])
        if tokens and os.path.basename(tokens[0]) == "git":
            found.append((tokens, cwd))
    return found


def names_git(event: dict) -> bool:
    """True when a Bash call may run git: "git" in its command once quotes and backslashes are removed."""
    if event.get("tool_name") != "Bash":
        return False
    return text_names_git(str((event.get("tool_input") or {}).get("command", "")))


def refuse_unparsable(command: str) -> None:
    """Refuse a command that names git but cannot be parsed."""
    first = command.strip().splitlines()[0] if command.strip() else command
    refuse(
        f"'{first}' (and what follows) cannot be parsed by the guard (a quote it reads differently from"
        " bash could hide a git command); ask the owner to run it"
    )


def parsed_segments(command: str) -> list[list[str]]:
    """segments(command), refusing the call when a command that names git cannot be parsed."""
    try:
        return segments(command)
    except Unparsable:
        refuse_unparsable(command)
        return []


def check_git_stop_conditions(event: dict, config: dict, cwd: str) -> None:
    """Refuse a Bash call with a git command that a stop condition forbids (unless "guard": false)."""
    if event.get("tool_name") != "Bash" or not guard_on(config):
        return
    base = str(config.get("base_branch") or "main")
    command = str((event.get("tool_input") or {}).get("command", ""))
    for tokens, at in git_commands(command, cwd):
        try:
            check_git(tokens, at, base)
        except Exception as error:  # fail closed: a git command the guard cannot parse is not let through
            git_refuse(" ".join(tokens), f"cannot be checked by the guard ({type(error).__name__})")


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
    git_only = sys.argv[1:2] == ["--git-only"]
    if git_only and not names_git(event):
        return
    config = load_config(cwd)
    if not git_only:
        check_scenarios(event, config, cwd)
    loop_dir = project_dir(cwd) if names_git(event) else ""
    if loop_dir and os.path.isfile(config_path(loop_dir)):
        check_git_stop_conditions(event, config if loop_dir == cwd else load_config(loop_dir), cwd)
    if git_only:
        return
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
    for tokens in parsed_segments(command):
        check_segment(tokens, roles, who)


if __name__ == "__main__":
    main()
