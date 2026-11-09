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

import fnmatch
import functools
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
# A redirection word at the head of a simple command (its target attached, or the next word when the word
# ends with an operator).
REDIRECTION = re.compile(r"^[0-9]*(?:<<<|<<-?|<>|>>|>\||[<>]&|[<>])", re.S)


class Unparsable(Exception):
    """A command that names git but that the guard cannot split as bash would (an unbalanced quote)."""


def text_names_git(text: str) -> bool:
    """True when text may name git: "git" in any case (GIT_ variables included) once line continuations
    (a backslash-newline after an even number of backslashes), quotes, backslashes, braces and commas are
    removed and $'...' escapes decoded, or a glob that may match git (such as gi? or g[i]t)."""
    joined = re.sub(r"(?<!\\)((?:\\\\)*)\\\n", r"\1", text)
    if "$'" in joined:
        joined += "\n" + ANSI_C_ESCAPE.sub(ansi_c_char, joined)
    if "git" in re.sub(r"[\\'\"{},]", "", joined).lower():
        return True
    globs = re.findall(r"[^\s;&|<>()'\"]*[*?[][^\s;&|<>()'\"]*", joined)
    return any(set(word.lower()) & set("git") and fnmatch.fnmatchcase("git", os.path.basename(word).lower())
               for word in globs)


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
        if command[index] in "'\"`":
            close = command.find(command[index], index + 1)
            index = len(command) if close < 0 else close + 1
        elif command.startswith("$(", index):
            index = arithmetic_end(command, index + 1)  # the word goes on to the matching )
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


ANSI_C_SIMPLE = {"a": "\a", "b": "\b", "e": "\x1b", "E": "\x1b", "f": "\f", "n": "\n", "r": "\r",
                 "t": "\t", "v": "\v", "\\": "\\", "'": "'", '"': '"', "?": "?"}
ANSI_C_ESCAPE = re.compile(r"\\(x[0-9A-Fa-f]{1,2}|u[0-9A-Fa-f]{1,4}|U[0-9A-Fa-f]{1,8}|[0-7]{1,3}|c.|.)", re.S)


def ansi_c_char(match: re.Match) -> str:
    """The text one $'...' escape stands for, as bash decodes it (an unknown escape stays as written)."""
    escape = match.group(1)
    if escape[0] in "xuU":
        code = int(escape[1:], 16)
        return chr(code) if code <= 0x10FFFF else match.group(0)
    if escape[0] in "01234567":
        return chr(int(escape, 8) & 0xFF)
    if escape[0] == "c" and len(escape) == 2:
        return chr(ord(escape[1]) & 0x1F)
    return ANSI_C_SIMPLE.get(escape, match.group(0))


def ansi_c_quoted(body: str) -> str:
    """A $'...' body decoded as bash decodes it (up to a NUL, where bash ends the string), as a plain
    single-quoted word, so an escaped name such as $'\\x67it' is still git."""
    text = ANSI_C_ESCAPE.sub(ansi_c_char, body).split("\0", 1)[0]
    return "'" + text.replace("'", "'\"'\"'") + "'"


def backtick_end(command: str, index: int) -> int:
    """The index after the backtick substitution that starts at index (the end when it never closes)."""
    index += 1
    while index < len(command) and command[index] != "`":
        index += 2 if command[index] == "\\" else 1
    return min(index + 1, len(command))


def plain_arithmetic(command: str, index: int) -> bool:
    """True when the $(( )) at index holds no command substitution (so it is one word with no command)."""
    body = command[index : arithmetic_end(command, index + 1)]
    return "$(" not in body[1:] and "`" not in body


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
    quote, index, glued = "", 0, False  # glued: the last step ended a $(( )) or $( ) inside a word
    while index < len(command):
        char = command[index]
        step, after = 1, glued
        glued = False
        if quote == "'":
            quote = "" if char == "'" else quote
        elif char == "\\" and command.startswith("\n", index + 1):
            index += 2  # a line continuation (outside single quotes): bash removes it
            continue
        elif char == "\\":
            step = 2
        elif char == "`":
            step = backtick_end(command, index) - index  # its own command: no here-document of ours inside
        elif quote == '"' and char == '"':
            quote = ""
        elif command.startswith("$((", index) and not quote and plain_arithmetic(command, index):
            end = arithmetic_end(command, index + 1)
            out.append(command[index:end].replace("(", "\\(").replace(")", "\\)"))  # one word for the lexer
            index, glued = end, True
            continue
        elif command.startswith("$((", index) or (not quote and command.startswith("((", index)):
            step = arithmetic_end(command, index + (1 if char == "$" else 0)) - index
        elif command.startswith("$(", index):
            stack.append([quote, 0])
            quote, step = "", 2
        elif quote:
            pass
        elif command.startswith((">&", "<&", ">|"), index):
            out.append(char + "\\" + command[index + 1])  # a redirection, not a separator, for the lexer
            index += 2
            continue
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
                quote, glued = stack.pop()[0], True
        elif char == "#" and not after and (not out or out[-1][-1:] in " \t\n;&|()"):
            end = command.find("\n", index)
            index = len(command) if end < 0 else end
            continue
        elif command.startswith("<<<", index):
            step = 3
        elif command.startswith("<<", index):
            parsed = heredoc_word(command, index + 2)
            if parsed:
                pending.append(parsed[:3])
                out.append("<<WORD")  # the delimiter is text: one plain word for the lexer
                index = parsed[3]
                continue
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
    command = strip_heredocs(command)
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
    """Drop leading variable assignments, redirections (>x, 2>&1, <<E, > x), reserved words (if, then, !,
    {, ...) and wrapper commands such as env, nice, timeout or nohup with their own options and values."""
    index = 0
    while index < len(segment):
        token = segment[index]
        wrapper = os.path.basename(token)
        redirect = REDIRECTION.match(token)
        if redirect:
            index += 2 if token.endswith(("<", ">", ">|")) else 1  # the target is the next word
        elif re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", token) or token in RESERVED:
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
GIT_GLOBAL_VALUE = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--config-env", "--super-prefix",
                    "--list-cmds", "--attr-source"}
REBASE_ACTIONS = {"continue", "abort", "skip", "quit", "edit-todo", "show-current-patch"}
CONFIG_READS = {"--get", "--get-all", "--get-regexp", "--get-urlmatch", "--get-color", "--get-colorbool", "--list",
                "-l"}
CONFIG_VALUE = {"-f", "--file", "--blob", "--type", "--default", "--comment"}
MAX_REFSPECS = 50
MAX_DIRS = 20

# The plain command line: what the git check reads. Programs that run a command string or a file of
# commands, compound commands, wrappers it follows, and programs whose arguments are only text.
RUNNERS = {"alias", "eval", "builtin", "command", "exec", "source", ".", "trap", "watch", "script", "flock", "su",
           "sudo", "doas", "busybox", "xargs", "parallel", "enable", "fc"}
COMPOUND = {"if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "select",
            "function", "coproc", "!", "[[", "]]"}
ALL_SHELLS = SHELLS | {"ash", "mksh", "yash", "fish", "csh", "tcsh"}
PLAIN_WRAPPERS = {name: WRAPPERS[name] for name in ("time", "nohup", "nice", "timeout", "stdbuf")}
# Programs whose arguments are only text: none runs a program its options name (sort, tar, less and the
# like are left out for that). The file writers (tee, cp, mv, ln, chmod, touch) can still build a script
# that a later command runs, a documented limit of the guard.
TEXT_PROGRAMS = {"echo", "printf", "grep", "egrep", "fgrep", "rg", "cat", "ls", "head", "tail", "wc", "test", "[",
                 "which", "type", "man", "true", "false", ":", "gh", "uniq", "cut", "tr", "diff", "cmp",
                 "basename", "dirname", "realpath", "readlink", "stat", "file", "du", "df", "mkdir", "touch", "rm",
                 "rmdir", "cp", "mv", "ln", "chmod", "tee", "jq", "pwd", "sleep", "date"}
DIR_PROGRAMS = {"cd", "pushd", "popd"}
DECLARERS = {"export", "declare", "typeset", "local", "readonly"}
# Variables that change which git runs, where, or with what config.
PROTECTED_ENV = re.compile(r"^(GIT_\w*|PATH|HOME|CDPATH|XDG_CONFIG_HOME|BASH_ENV|ENV|LD_PRELOAD)$")
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*(?:\[[^\]]*\])?\+?=")
# Text that reads as a git command line ("git push", "/usr/lib/git-core/git-push origin"): a program
# given it may run it.
GIT_TEXT = re.compile(r"(?<![\w.-])git(?:-[\w-]+)?\s", re.IGNORECASE)
REDIRECT_OPS = ("<<<", "<<-", "&>>", "<<", ">>", ">|", "<>", ">&", "<&", "&>", "<", ">")
HEREDOC_WORD = re.compile(r"""(?:'([\w.-]+)'|"([\w.-]+)"|\\([\w.-]+)|([\w.-]+))(?=[\s;&|<>]|$)""")


class NotPlain(Exception):
    """A command naming git that is not a plain command line; the message says what is not plain."""


class Word:
    """One shell word: its literal text, whether any of it was quoted, whether it has an unquoted glob
    character, the offset of its first quoted character (-1 when none) and, for a redirection target, its
    operator."""

    def __init__(self, text: str = "") -> None:
        self.text, self.quoted, self.glob, self.first_quote = text, False, False, -1
        self.op = ""  # for a redirection target: its operator (">", ">>", "<<", ...)


class Simple:
    """A simple command: its words, its redirection targets (here-document bodies included) and the
    operator after it ("" at the end)."""

    def __init__(self) -> None:
        self.words: list[Word] = []
        self.targets: list[Word] = []
        self.op = ""


class PlainLexer:
    """Splits a plain command line into simple commands, as bash reads it; raises NotPlain on anything that
    is not literal (an expansion, a brace, a subshell, a background &, an unbalanced quote, ...)."""

    def __init__(self, text: str) -> None:
        self.text, self.index = text, 0
        self.commands = [Simple()]
        self.pending: list[tuple[bool, bool, str, Word]] = []  # here-documents waiting for their bodies
        self.word: Word | None = None
        self.redirect = ""  # a redirection waiting for its target word

    def run(self) -> list[Simple]:
        """The simple commands of the text."""
        text = self.text
        while self.index < len(text):
            char = text[self.index]
            if char in " \t":
                self.end_word()
                self.index += 1
            elif char == "\\":
                self.backslash()
            elif char == "'":
                self.single_quote()
            elif char == '"':
                self.double_quote()
            elif char in "$`":
                raise NotPlain(f"a {char} expansion")
            elif char in "{}()":
                raise NotPlain(f"a {char} (braces, subshells and functions are not plain)")
            elif char == "#" and self.word is None:
                end = text.find("\n", self.index)
                self.index = len(text) if end < 0 else end
            elif char in "<>" or text.startswith("&>", self.index):
                self.redirection()
            elif char in ";|&\n":
                self.operator()
            else:
                self.add(char, glob=char in GLOB_CHARS)
                self.index += 1
        self.end_word()
        if self.pending:
            raise NotPlain("a here-document without its end line")
        if self.redirect:
            raise NotPlain("a redirection without a target")
        return [command for command in self.commands if command.words or command.targets]

    def add(self, chars: str, quoted: bool = False, glob: bool = False) -> None:
        """Append chars to the current word (starting one)."""
        if self.word is None:
            self.word = Word()
        word = self.word
        if quoted and word.first_quote < 0:
            word.first_quote = len(word.text)
        word.text += chars
        word.quoted, word.glob = word.quoted or quoted, word.glob or glob

    def end_word(self) -> None:
        """Finish the current word: a leading unquoted ~ is the home directory; the word is the pending
        redirection's target or the next word of the command."""
        word, self.word = self.word, None
        if word is None:
            return
        if word.first_quote != 0 and (word.text == "~" or word.text.startswith("~/")):
            word.text = os.environ.get("HOME", "") + word.text[1:]
        if self.redirect:
            word.op = self.redirect
            self.commands[-1].targets.append(word)
            self.redirect = ""
        else:
            self.commands[-1].words.append(word)

    def backslash(self) -> None:
        """A backslash quotes the next character; before a newline it continues the line."""
        following = self.text[self.index + 1 : self.index + 2]
        if following != "\n":
            self.add(following or "\\", quoted=True)
        self.index += 2

    def single_quote(self) -> None:
        """A single-quoted string: literal up to the next single quote."""
        end = self.text.find("'", self.index + 1)
        if end < 0:
            raise NotPlain("an unbalanced quote")
        self.add(self.text[self.index + 1 : end], quoted=True)
        self.index = end + 1

    def double_quote(self) -> None:
        """A double-quoted string without $ or backticks; a backslash quotes $ ` " \\ and newline only."""
        text, index, out = self.text, self.index + 1, []
        while index < len(text) and text[index] != '"':
            char = text[index]
            if char in "$`":
                raise NotPlain(f"a {char} expansion")
            if char == "\\" and text[index + 1 : index + 2] in {"$", "`", '"', "\\", "\n"}:
                out.append("" if text[index + 1] == "\n" else text[index + 1])
                index += 2
            else:
                out.append(char)
                index += 1
        if index >= len(text):
            raise NotPlain("an unbalanced quote")
        self.add("".join(out), quoted=True)
        self.index = index + 1

    def redirection(self) -> None:
        """A redirection operator (a file descriptor number before it is part of it); a here-document
        reads its end word now and its body after the next newline."""
        word = self.word
        if word is not None and word.text.isdigit() and not word.quoted and self.text[self.index] in "<>":
            self.word = None
        else:
            self.end_word()
        if self.redirect:
            raise NotPlain("a redirection without a target")
        operator = next(op for op in REDIRECT_OPS if self.text.startswith(op, self.index))
        self.index += len(operator)
        if operator in {"<<", "<<-"}:
            self.heredoc(operator == "<<-")
        else:
            self.redirect = operator

    def heredoc(self, strip_tabs: bool) -> None:
        """The end word of a here-document: one plain word, maybe quoted as a whole."""
        while self.index < len(self.text) and self.text[self.index] in " \t":
            self.index += 1
        match = HEREDOC_WORD.match(self.text, self.index)
        if not match:
            raise NotPlain("a here-document end word that is not one plain word")
        body = Word()
        body.op = "<<"
        self.commands[-1].targets.append(body)
        delimiter = next(group for group in match.groups() if group)
        self.pending.append((strip_tabs, match.group(4) is None, delimiter, body))
        self.index = match.end()

    def operator(self) -> None:
        """&&, ||, ;, |, |& or a newline (which starts the pending here-document bodies); a lone & is not
        plain."""
        self.end_word()
        if self.redirect:
            raise NotPlain("a redirection without a target")
        pair = self.text[self.index : self.index + 2]
        if pair in {"&&", "||", "|&"}:
            operator, size = ("|" if pair == "|&" else pair), 2
        elif pair[0] == "&":
            raise NotPlain("a background &")
        else:
            operator, size = pair[0], 1
        self.commands[-1].op = operator
        self.commands.append(Simple())
        self.index += size
        if operator == "\n" and self.pending:
            self.bodies()

    def bodies(self) -> None:
        """Read the pending here-document bodies; an unquoted end word's body must expand nothing."""
        text = self.text
        for strip_tabs, quoted, delimiter, body in self.pending:
            lines = []
            while True:
                if self.index >= len(text):
                    raise NotPlain("a here-document without its end line")
                end = text.find("\n", self.index)
                end = len(text) if end < 0 else end
                line, self.index = text[self.index : end], end + 1
                if (line.lstrip("\t") if strip_tabs else line) == delimiter:
                    break
                if not quoted and any(char in line for char in "$`\\"):
                    raise NotPlain("a here-document body with $, backticks or backslashes and an unquoted end word")
                lines.append(line)
            body.text, body.quoted = "\n".join(lines), True
        self.pending = []


class Directories:
    """The directories the next command may run in, following cd, pushd and popd across &&, ||, ; and
    newlines: a cd that may fail or be skipped keeps the directory before it possible."""

    def __init__(self, cwd: str) -> None:
        self.dirs = {cwd}
        self.fallback: set[str] = set()  # directories before a cd of this and-or list
        self.stack: list[set[str]] = []

    def change(self, program: str, args: list[Word], previous: str) -> None:
        """Apply cd, pushd or popd (previous: the operator before it)."""
        old = set(self.dirs)
        if program == "popd":
            if args or not self.stack:
                raise NotPlain("a popd the guard cannot follow")
            new = self.stack.pop()
        else:
            target = dir_target(program, args)
            new = {os.path.normpath(os.path.join(directory, target)) for directory in old}
            if program == "pushd":
                self.stack.append(old)
        self.dirs = new | old if previous == "||" else new
        self.fallback |= old
        if len(self.dirs | self.fallback) > MAX_DIRS:
            raise NotPlain("more directory changes than the guard follows")

    def after(self, operator: str) -> None:
        """After || ; or a newline the directories before a failed cd are possible again."""
        if operator in {"||", ";", "\n", ""}:
            self.dirs = self.dirs | self.fallback  # a new set: the old one may be in use by a git command
        if operator in {";", "\n", ""}:
            self.fallback = set()


def dir_target(program: str, args: list[Word]) -> str:
    """The directory a plain cd or pushd changes to (HOME for a bare cd)."""
    words = [word for word in args if word.text not in {"-L", "-P", "--"}]
    if not words:
        if program == "pushd":
            raise NotPlain("a pushd without a directory")
        return os.environ.get("HOME", "/")
    target = words[0]
    if target.text.startswith(("-", "+")) or target.glob:
        raise NotPlain(f"a {program} the guard cannot follow ({target.text})")
    return target.text


def is_assignment(word: Word) -> bool:
    """True when a word is a variable assignment (its = unquoted)."""
    match = ASSIGNMENT.match(word.text)
    return bool(match) and (word.first_quote < 0 or match.end() <= word.first_quote)


def check_assignment(text: str) -> None:
    """Refuse an assignment to a variable that changes what git runs, or of text naming a git command."""
    name = re.split(r"[\[+=]", text, maxsplit=1)[0]
    if PROTECTED_ENV.match(name):
        raise NotPlain(f"it sets {name}, which changes which git runs, where, or with what config")
    if GIT_TEXT.search(text.partition("=")[2] + " "):
        raise NotPlain(f"it stores text naming git in {name}")


def skip_env(words: list[Word], index: int, dirs: set[str]) -> tuple[int, set[str]]:
    """The index after env's options and assignments, and the directories its -C/--chdir gives."""
    while index < len(words):
        text = words[index].text
        value = None
        if ASSIGNMENT.match(text):
            check_assignment(text)
        elif text == "--":
            return index + 1, dirs
        elif not text.startswith("-") or text == "-":
            return index, dirs
        elif text.startswith("--"):
            name, equals, value = text[2:].partition("=")
            if "split-string".startswith(name):
                raise NotPlain("env -S splits a string into a command")
            if not equals and any(option.startswith(name) for option in ("chdir", "unset", "argv0")):
                value, index = (words[index + 1].text if index + 1 < len(words) else ""), index + 1
            value = value if "chdir".startswith(name) else None
        else:
            for position, letter in enumerate(text[1:]):
                if letter == "S":
                    raise NotPlain("env -S splits a string into a command")
                if letter in "Cua":
                    rest = text[position + 2 :]
                    if not rest:
                        rest, index = (words[index + 1].text if index + 1 < len(words) else ""), index + 1
                    value = rest if letter == "C" else None
                    break
        if value is not None:
            if GLOB_CHARS & set(value):
                raise NotPlain(f"an env -C the guard cannot follow ({value})")
            dirs = {os.path.normpath(os.path.join(directory, value)) for directory in dirs}
        index += 1
    return index, dirs


def unwrap(words: list[Word], dirs: set[str]) -> tuple[int, set[str]]:
    """The index of the program word after assignments and wrappers (env, time, nohup, nice, timeout,
    stdbuf, as-role.sh ROLE, heavy.sh), and the directories it runs in."""
    index = 0
    while index < len(words) and is_assignment(words[index]):
        check_assignment(words[index].text)
        index += 1
    texts = [word.text for word in words]
    while index < len(words):
        name = os.path.basename(texts[index])
        if name == "env":
            index, dirs = skip_env(words, index + 1, dirs)
        elif name in PLAIN_WRAPPERS:
            index = skip_wrapper_options(texts, index + 1, name)
        elif name in {"as-role.sh", "heavy.sh"}:
            index += 2 if name == "as-role.sh" else 1
        else:
            break
    return index, dirs


def man_runs(text: str) -> bool:
    """True when a man option names a program to run (-H, -P, --html, --pager, or a prefix of them)."""
    if text.startswith("--"):
        name = text[2:].split("=", 1)[0]
        return bool(name) and ("html".startswith(name) or "pager".startswith(name))
    return text.startswith("-") and bool(set(text[1:]) & {"H", "P"})


def check_program(program: str, texts: list[str]) -> None:
    """Refuse a program that runs a command string the guard cannot read, or changes git's environment."""
    if program in COMPOUND:
        raise NotPlain(f"a compound command ({program} ...)")
    if program in RUNNERS:
        raise NotPlain(f"{program} runs a command the guard cannot read")
    if program in ALL_SHELLS and (len(texts) < 2 or texts[1].startswith(("-", "+"))):
        raise NotPlain(f"{program} reads its commands from a string or stdin")
    if program == "find" and {"-exec", "-execdir", "-ok", "-okdir"} & set(texts):
        raise NotPlain("find -exec runs a command")
    if program == "rg" and any(text == "--pre" or text.startswith("--pre=") for text in texts):
        raise NotPlain("rg --pre runs a command")
    if program == "man" and any(man_runs(text) for text in texts[1:]):
        raise NotPlain("man -H/-P/--html/--pager runs a command")
    if program == "gh" and texts[1:2] == ["alias"]:
        raise NotPlain("gh alias defines a command")
    if program in DECLARERS:
        for text in texts[1:]:
            if not text.startswith("-"):
                check_assignment(text if "=" in text else text + "=")


def other_program(words: list[Word], targets: list[Word], dirs: set[str]) -> list[tuple[list[str], set[str]]]:
    """For a program the guard does not know: every word git (or git-<name>) starts a git command, since
    the program may run it; text naming git before it, or in its input, is refused."""
    program = words[0].text if words else ""
    if any(GIT_TEXT.search(target.text + " ") for target in targets if target.quoted):
        raise NotPlain(f"{program or 'a command'} reads text naming git, which it may run")
    for position, word in enumerate(words):
        name = os.path.basename(word.text).lower()
        if name == "git" or name.startswith("git-"):
            return [(git_argv([word.text for word in words[position:]]), dirs)]
        if word.glob and fnmatch.fnmatchcase("git", os.path.basename(word.text).lower()):
            raise NotPlain(f"a glob that may match git ({word.text})")
        if GIT_TEXT.search(word.text):
            raise NotPlain(f"{program} is given text naming git, which it may run")
    return []


def git_argv(texts: list[str]) -> list[str]:
    """A git command's argv, with git-<name> read as git <name>."""
    name = os.path.basename(texts[0]).lower()
    return ["git", name[4:]] + texts[1:] if name.startswith("git-") else ["git"] + texts[1:]


def git_invocations(commands: list[Simple], cwd: str) -> list[tuple[list[str], set[str]]]:
    """The git commands of a plain command line, each with the directories it may run in; refuses
    (NotPlain) what may run text the guard cannot read."""
    found: list[tuple[list[str], set[str]]] = []
    where, previous, tainted = Directories(cwd), "", False
    for command in commands:
        index, dirs = unwrap(command.words, where.dirs)
        words = command.words[index:]
        texts = [word.text for word in words]
        program = os.path.basename(texts[0]).lower() if texts else ""
        tainted = tainted and previous == "|"
        if words and words[0].glob:
            raise NotPlain(f"a glob as the command name ({texts[0]})")
        check_program(program, texts)
        if program in DIR_PROGRAMS:
            if "|" in {previous, command.op}:
                raise NotPlain(f"a {program} in a pipeline")
            where.change(program, words[1:], previous)
        elif program == "git" or program.startswith("git-"):
            found.append((git_argv(texts), dirs))
        elif program and program not in TEXT_PROGRAMS:
            if tainted:
                raise NotPlain(f"text naming git is piped into {program}, which may run it")
            found += other_program(words, command.targets, dirs)
        if not (program == "git" or program.startswith("git-")):
            tainted = tainted or bool(GIT_TEXT.search(" ".join(w.text for w in command.words + command.targets) + " "))
        previous = command.op
        where.after(command.op)
    return found


def guard_on(config: dict) -> bool:
    """The git check is on unless the project's config says "guard": false."""
    return config.get("guard") is not False


def git_refuse(command: str, why: str) -> None:
    """Refuse a git command that a stop condition forbids."""
    shown = command if len(command) <= 200 else command[:200] + " ..."
    refuse(f"'{shown}' is refused: it {why}, which is a stop condition; ask the owner to run it")


def refuse_not_plain(command: str, reason: str) -> None:
    """Refuse a command that names git but is not a plain command line."""
    first = command.strip().splitlines()[0][:120] if command.strip() else command
    refuse(
        f"'{first}' is refused: it names git but is not a plain command line ({reason}), so the guard"
        " cannot tell what it runs. Write it plainly: literal words joined by &&, ||, ;, | or newlines, no $"
        " or backtick expansions, braces, subshells, functions, aliases, eval or sh -c; a commit message as"
        " git commit -F - <<'EOF' (a quoted end word). Or ask the owner to run it"
    )


def git_split(tokens: list[str], dirs: set[str]) -> tuple[str, list[str], set[str], set[str]]:
    """(subcommand, its arguments, the directories git runs in, the global options that matter: "config"
    for -c/--config-env, "elsewhere" for --git-dir/--work-tree, "exec-path" for --exec-path=<dir>)."""
    index, flags = 1, set()
    while index < len(tokens):
        token = tokens[index]
        name = token.split("=", 1)[0]
        if name in {"-c", "--config-env"}:
            flags.add("config")
        if name in {"--git-dir", "--work-tree"}:
            flags.add("elsewhere")
        if name == "--exec-path" and "=" in token:
            flags.add("exec-path")
        if token in GIT_GLOBAL_VALUE:
            value = tokens[index + 1] if index + 1 < len(tokens) else ""
            if token == "-C":
                dirs = {os.path.normpath(os.path.join(directory, value)) for directory in dirs}
                flags |= {"glob"} if GLOB_CHARS & set(value) else set()
            index += 2
        elif token.startswith("-"):
            index += 1
        else:
            break
    if index >= len(tokens):
        return "", [], dirs, flags
    sub, rest = tokens[index].lower(), tokens[index + 1 :]
    if sub == "worktree" and rest[:1] == ["remove"]:
        sub, rest = "worktree remove", rest[1:]
    return sub, rest, dirs, flags


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


@functools.lru_cache(maxsize=None)
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


@functools.lru_cache(maxsize=None)
def local_refs(cwd: str) -> tuple[frozenset[str], frozenset[str]]:
    """(the branch names, the tag names) of the repository in cwd, from one git show-ref."""
    try:
        lines = subprocess.run(["git", "-C", cwd, "show-ref"], capture_output=True, text=True).stdout.splitlines()
    except OSError:
        lines = []
    refs = [line.partition(" ")[2] for line in lines]
    heads = frozenset(ref[len("refs/heads/") :] for ref in refs if ref.startswith("refs/heads/"))
    tags = frozenset(ref[len("refs/tags/") :] for ref in refs if ref.startswith("refs/tags/"))
    return heads, tags


def names_base(ref: str, base: str) -> bool:
    """True when a ref as written in a refspec names the base branch (in any case)."""
    return ref.lower() in {base.lower(), f"heads/{base}".lower(), f"refs/heads/{base}".lower()}


def config_reads(args: list[str]) -> bool:
    """True when a git config command only reads (--get*, --list/-l, get, list)."""
    index = 0
    while index < len(args):
        arg = args[index]
        if arg in CONFIG_READS:
            return True
        if arg in CONFIG_VALUE:
            index += 2
        elif arg.startswith("-"):
            index += 1
        else:
            return arg in {"get", "list"}
    return False


def push_texts(options: list[tuple[str, str]], positional: list[str], base: str, command: str) -> list[tuple[str, str]]:
    """Refuse a push whose refspecs, as written, force, delete, tag or name the base branch; the
    (source, destination) pairs left for the checks that need git (destination empty when not given)."""
    repo_given = any(option == "repo" for option, _ in options)
    refspecs = positional if repo_given else positional[1:]
    pairs = []
    for spec in refspecs or ["HEAD"]:
        if spec == "tag":
            git_refuse(command, "pushes a tag (tag <name>)")
        if spec.startswith("+"):
            git_refuse(command, f"force-pushes ({spec})")
        if GLOB_CHARS & set(spec):
            git_refuse(command, f"pushes every ref a pattern matches, the base branch maybe included ({spec})")
        source, colon, destination = spec.partition(":")
        if colon and not source:
            git_refuse(command, f"deletes a remote branch ({spec})")
        for ref in (source, destination):
            if ref.lower().startswith(("refs/tags/", "tags/")):
                git_refuse(command, f"pushes a tag ({spec})")
            if names_base(ref, base):
                git_refuse(command, f"pushes the base branch {base} ({spec})")
        pairs.append((source, destination))
    if len(refspecs) > MAX_REFSPECS:
        git_refuse(command, f"pushes {len(refspecs)} refspecs, more than the guard checks ({MAX_REFSPECS})")
    return pairs


def push_refs(pairs: list[tuple[str, str]], dirs: set[str], base: str, command: str) -> None:
    """Refuse a push of HEAD (or @) from a directory where the base branch is checked out or where the
    branch cannot be read, and a push of a name that is a tag and not a branch."""
    for directory in sorted(dirs):
        heads, tags = local_refs(directory)
        for source, destination in pairs:
            ref = source
            if source in {"HEAD", "@"}:
                ref = current_branch(directory)
                if not ref:
                    git_refuse(command, f"pushes HEAD from {directory}, a directory the guard cannot read, so maybe"
                               " the base branch")
            if names_base(ref, base):
                git_refuse(command, f"pushes the base branch {base} ({source} in {directory})")
            for name in (ref, destination):
                if name in tags and name not in heads:
                    git_refuse(command, f"pushes a tag ({name})")


def rebase_branch(dirs: set[str], base: str, command: str) -> None:
    """Refuse a rebase of HEAD where the base branch is checked out."""
    for directory in sorted(dirs):
        if names_base(current_branch(directory), base):
            git_refuse(command, f"rewrites the base branch {base} (checked out in {directory})")


def check_rebase(options: list[tuple[str, str]], positional: list[str], dirs: set[str], base: str,
                 command: str) -> list:
    """Refuse a rebase whose rewritten branch, as written, is the base branch; the check of HEAD is left
    for later (it needs git)."""
    names = {option for option, _ in options}
    if names & REBASE_ACTIONS:
        return []
    wanted = 0 if "root" in names else 1
    branch = positional[wanted] if len(positional) > wanted else "HEAD"
    if branch not in {"HEAD", "@"}:
        if names_base(branch, base):
            git_refuse(command, f"rewrites the base branch {base}")
        return []
    return [functools.partial(rebase_branch, dirs, base, command)]


def check_git(tokens: list[str], dirs: set[str], base: str) -> list:
    """Refuse a git command whose text hits a stop condition; returns the checks that need git itself (the
    branch checked out, the tags), which run after every text check."""
    sub, args, dirs, flags = git_split(tokens, dirs)
    command = " ".join(tokens)
    if "config" in flags:
        git_refuse(command, "injects git config (-c/--config-env), which can run a command (aliases, pagers, ssh)")
    if "exec-path" in flags:
        git_refuse(command, "runs git commands from another directory (--exec-path)")
    if "glob" in flags:
        git_refuse(command, "runs in a directory a glob names (-C)")
    if "elsewhere" in flags and sub in {"push", "rebase"}:
        git_refuse(command, f"{sub}es another repository's branch (--git-dir/--work-tree), maybe the base")
    if sub == "config" and not config_reads(args):
        git_refuse(command, "writes git config (an alias or a hook can run any command)")
    if (sub == "submodule" and "foreach" in args) or (sub == "bisect" and "run" in args):
        git_refuse(command, f"runs a command string ({sub} {'foreach' if sub == 'submodule' else 'run'})")
    if sub == "filter-branch":
        git_refuse(command, "runs command strings (filter-branch)")
    if sub not in GIT_LONG:
        return []
    options, positional = git_parse(sub, args)
    for option, _ in options:
        if option in GIT_DANGER.get(sub, {}):
            git_refuse(command, GIT_DANGER[sub][option])
    if sub == "push":
        pairs = push_texts(options, positional, base, command)
        return [functools.partial(push_refs, pairs, dirs, base, command)]
    if sub == "rebase":
        return check_rebase(options, positional, dirs, base, command)
    return []


def names_git(event: dict) -> bool:
    """True when a Bash call may run git (text_names_git on its command)."""
    if event.get("tool_name") != "Bash":
        return False
    return text_names_git(str((event.get("tool_input") or {}).get("command", "")))


def refuse_unparsable(command: str) -> None:
    """Refuse a command that names git but cannot be parsed (identity and scenario checks)."""
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
    """Refuse a Bash call that names git unless it is a plain command line whose git commands hit no stop
    condition (unless "guard": false). Text checks run first; the checks that need git run once each."""
    if event.get("tool_name") != "Bash" or not guard_on(config):
        return
    base = str(config.get("base_branch") or "main")
    command = str((event.get("tool_input") or {}).get("command", ""))
    if not text_names_git(command):
        return
    try:
        invocations = git_invocations(PlainLexer(command).run(), cwd)
    except NotPlain as error:
        refuse_not_plain(command, str(error))
        return
    deferred = []
    for tokens, dirs in invocations:
        deferred += check_git(tokens, dirs, base)
    for check in deferred:
        check()


# Targeted commands (#72): the runner forms a "targeted" entry may start with, and the flags that are safe
# after each, as {flag: "none" | "value" | "optional"} (a value that is the next word or follows "="; an
# optional one only attached, or a next word of digits). Style "go": one or two dashes, -flag=value, no
# bundles; style "gnu": bundled short letters (-xvs, -kEXPR), --long and --long=value. A form ending in
# "<word>" needs one more plain word in the entry (a make target, an npm script). Every other flag, "--",
# and anything the runner would read as a setting is refused, so the lists stay small.
NO, VAL, OPT = "none", "value", "optional"
GO_TEST_FLAGS = {"-run": VAL, "-skip": VAL, "-count": VAL, "-v": NO, "-race": NO, "-short": NO, "-timeout": VAL,
                 "-failfast": NO, "-cover": NO, "-covermode": VAL, "-parallel": VAL, "-cpu": VAL, "-bench": VAL,
                 "-benchtime": VAL, "-benchmem": NO, "-json": NO, "-shuffle": VAL, "-tags": VAL}
GO_VET_FLAGS = {"-json": NO, "-tags": VAL}
GOFMT_FLAGS = {"-l": NO, "-d": NO, "-s": NO, "-e": NO, "-w": NO}
PYTEST_FLAGS = {"-k": VAL, "-m": VAL, "-x": NO, "-q": NO, "-v": NO, "-s": NO, "-l": NO, "-r": VAL, "-n": VAL,
                "--lf": NO, "--ff": NO, "--last-failed": NO, "--failed-first": NO, "--exitfirst": NO, "--quiet": NO,
                "--verbose": NO, "--maxfail": VAL, "--tb": VAL, "--durations": VAL, "--no-header": NO,
                "--showlocals": NO}
NODE_FLAGS = {"--silent": NO}
CARGO_TEST_FLAGS = {"-q": NO, "--quiet": NO, "-v": NO, "--verbose": NO, "--release": NO, "--lib": NO, "--bins": NO,
                    "--tests": NO, "--doc": NO, "--no-fail-fast": NO, "-p": VAL, "--package": VAL, "--test": VAL,
                    "--features": VAL, "-F": VAL, "--all-features": NO, "--no-default-features": NO,
                    "--workspace": NO, "-j": VAL, "--jobs": VAL, "--locked": NO, "--offline": NO}
CARGO_FMT_FLAGS = {"--check": NO, "--all": NO, "-p": VAL, "--package": VAL, "-q": NO, "--quiet": NO, "-v": NO,
                   "--verbose": NO}
MAKE_FLAGS = {"-j": OPT, "--jobs": OPT, "-k": NO, "--keep-going": NO, "-s": NO, "--silent": NO}
RUFF_CHECK_FLAGS = {"--fix": NO, "--diff": NO, "-q": NO, "--quiet": NO, "--statistics": NO, "--no-cache": NO}
RUFF_FORMAT_FLAGS = {"--check": NO, "--diff": NO, "-q": NO, "--quiet": NO, "--no-cache": NO}
TARGETED_FORMS = [
    (("go", "test"), "go", GO_TEST_FLAGS), (("go", "vet"), "go", GO_VET_FLAGS), (("gofmt",), "go", GOFMT_FLAGS),
    (("pytest",), "gnu", PYTEST_FLAGS), (("python", "-m", "pytest"), "gnu", PYTEST_FLAGS),
    (("python3", "-m", "pytest"), "gnu", PYTEST_FLAGS), (("uv", "run", "pytest"), "gnu", PYTEST_FLAGS),
    (("npm", "test"), "gnu", NODE_FLAGS), (("pnpm", "test"), "gnu", NODE_FLAGS), (("yarn", "test"), "gnu", NODE_FLAGS),
    (("npm", "run", "<word>"), "gnu", NODE_FLAGS), (("pnpm", "run", "<word>"), "gnu", NODE_FLAGS),
    (("yarn", "run", "<word>"), "gnu", NODE_FLAGS),
    (("cargo", "test"), "gnu", CARGO_TEST_FLAGS), (("cargo", "fmt"), "gnu", CARGO_FMT_FLAGS),
    (("make", "<word>"), "gnu", MAKE_FLAGS),
    (("ruff", "check"), "gnu", RUFF_CHECK_FLAGS), (("ruff", "format"), "gnu", RUFF_FORMAT_FLAGS),
    (("uv", "run", "ruff", "check"), "gnu", RUFF_CHECK_FLAGS),
    (("uv", "run", "ruff", "format"), "gnu", RUFF_FORMAT_FLAGS),
]
INTERPRETERS = {"python", "python3", "node", "bun", "deno", "ruby", "perl", "php", "uv", "uvx", "pipx", "npx", "pnpx",
                "bunx", "java", "go"}
TARGETED_ENTRY = re.compile(r"^[A-Za-z0-9_./:@%+,= -]+$")
SAFE_DEVICES = {"/dev/null", "/dev/stdout", "/dev/stderr"}


def form_words(form: tuple) -> tuple:
    """The fixed words of a runner form (without a trailing <word>)."""
    return form[:-1] if form[-1] == "<word>" else form


def match_form(texts: list[str]) -> tuple | None:
    """The longest runner form (words, style, flags) whose fixed words start texts (the program by its
    basename), or None."""
    best = None
    for form, style, flags in TARGETED_FORMS:
        fixed = form_words(form)
        if len(texts) < len(fixed) or os.path.basename(texts[0]) != fixed[0]:
            continue
        if tuple(texts[1 : len(fixed)]) != fixed[1:]:
            continue
        if best is None or len(fixed) > len(form_words(best[0])):
            best = (form, style, flags)
    return best


def within(path: str, root: str) -> bool:
    """True when path, as written and with symlinks resolved, is root or below it."""
    pairs = ((os.path.normpath(path), os.path.normpath(root)), (os.path.realpath(path), os.path.realpath(root)))
    return all(candidate == top or candidate.startswith(top.rstrip("/") + "/") for candidate, top in pairs)


def positional_problem(word: Word, dirs: set[str], root: str) -> str | None:
    """Why a word that is not a flag is not a plain path, package or pattern inside the project, or None."""
    text = word.text
    if not text:
        return "an empty argument"
    if text.startswith(("-", "+")):
        return f"{text} is not on the safe list"
    if "=" in text:
        return f"{text} is a setting (VAR=value), which the runner reads as configuration"
    if re.search(r"[\s\x00-\x1f]", text):
        return f"'{text}' holds blanks or control characters"
    for directory in sorted(dirs):
        if not within(os.path.join(directory, text), root):
            return f"{text} is a path outside the project"
    return None


def flag_problem(style: str, flags: dict, args: list[Word], index: int) -> tuple[str | None, int]:
    """(why the flag at index is refused or None, the index after it and its value)."""
    text = args[index].text
    index += 1
    if text in {"--", "--end-of-options"}:
        return f"{text} passes what follows to the runner unchecked", index
    if style == "go" or text.startswith("--"):
        key, eq, _ = text.partition("=")
        if style == "go" and key.startswith("--"):
            key = key[1:]
        kind = flags.get(key)
        if kind is None or (kind == NO and eq):
            return f"{text} is not on the safe list", index
        if not eq and kind == VAL:
            index += 1
        elif not eq and kind == OPT and index < len(args) and args[index].text.isdigit():
            index += 1
        return None, index
    letters = text[1:]
    while letters:
        kind = flags.get("-" + letters[0])
        if kind is None:
            return f"{text} is not on the safe list (-{letters[0]})", index
        rest, letters = letters[1:], letters[1:]
        if kind == VAL:
            index += 0 if rest else 1
            break
        if kind == OPT:
            if not rest and index < len(args) and args[index].text.isdigit():
                index += 1
            break
    return None, index


def arguments_problem(style: str, flags: dict, args: list[Word], dirs: set[str], root: str) -> str | None:
    """Why the arguments after a runner form are refused (the first bad one), or None."""
    index = 0
    while index < len(args):
        word = args[index]
        if word.glob:
            return f"{word.text} is a glob the shell expands"
        if word.text.startswith("-") and word.text != "-":
            problem, after = flag_problem(style, flags, args, index)
            if problem:
                return problem
            if any(arg.glob for arg in args[index + 1 : after]):
                return f"{args[after - 1].text} is a glob the shell expands"
            index = after
            continue
        problem = positional_problem(word, dirs, root)
        if problem:
            return problem
        index += 1
    return None


def redirect_problem(targets: list[Word], dirs: set[str], root: str) -> str | None:
    """Why an output redirection of a targeted command is refused (a file outside the project), or None."""
    for target in targets:
        if ">" not in target.op or target.text in SAFE_DEVICES:
            continue
        if target.op in {">&", "<&"} and (target.text.isdigit() or target.text == "-"):
            continue
        if any(not within(os.path.join(directory, target.text), root) for directory in dirs):
            return f"it writes {target.text}, outside the project"
    return None


def targeted_refusal(entry: str) -> str:
    """Why a "targeted" entry cannot become an allow rule; empty when it can."""
    if not entry.strip():
        return "it is empty"
    if not TARGETED_ENTRY.match(entry):
        return "it holds shell metacharacters, quotes or a wildcard (list the plain command prefix)"
    words = entry.split()
    if "/" in words[0]:
        return f"the program {words[0]} is a path (name the runner, such as \"make test\")"
    if words[0] == "git":
        return "git commands stay with the template's exact git rules and the git guard"
    found = match_form(words)
    if found is None:
        if words[0] in ALL_SHELLS:
            return f"{words[0]} is a shell, which runs any command string"
        if words[0] in {"npx", "pnpx", "bunx", "uvx", "pipx"}:
            return f"{words[0]} downloads and runs any package"
        if words[0] in INTERPRETERS and words[0] != "go":
            return f"{words[0]} is an interpreter, which runs any code (list a runner form, e.g. \"python -m pytest\")"
        return "not an accepted runner form (" + ", ".join(" ".join(form) for form, _, _ in TARGETED_FORMS) + ")"
    form, style, flags = found
    rest = [Word(text) for text in words[len(form_words(form)) :]]
    if form[-1] == "<word>" and not rest:
        what = "target" if form[0] == "make" else "script"
        return f"a bare runner: name the {what} (\"{entry} <{what}>\")"
    problem = arguments_problem(style, flags, rest, {"/project"}, "/project")
    return problem or ""


def targeted_forms(config: dict) -> list[tuple]:
    """The runner forms of the project's accepted "targeted" entries."""
    entries = config.get("targeted")
    if not isinstance(entries, list):
        return []
    forms = []
    for entry in entries:
        if isinstance(entry, str) and not targeted_refusal(" ".join(entry.split())):
            found = match_form(entry.split())
            if found and found not in forms:
                forms.append(found)
    return forms


def runner_named(text: str, forms: list[tuple]) -> bool:
    """True when text, quotes and backslashes removed, names the program of one of the runner forms as a
    word."""
    plain = re.sub(r"[\\'\"]", "", text)
    names = sorted({re.escape(form[0][0]) for form in forms})
    return bool(re.search(r"(?<![\w.-])(?:" + "|".join(names) + r")(?![\w.-])", plain))


def configured_argvs(config: dict) -> list[list[str]]:
    """The simple commands of fast_check and checks as argv lists: they have exact allow rules."""
    commands = [config.get("fast_check")]
    for check in config.get("checks") or []:
        commands.append(check.get("command") if isinstance(check, dict) else check)
    argvs = []
    for command in commands:
        if not isinstance(command, str):
            continue
        for part in re.split(r"\|\||&&|\|&|;|\||&", command):
            try:
                argv = shlex.split(part)
            except ValueError:
                continue
            if argv:
                argvs.append(argv)
    return argvs


def toplevel(directory: str) -> str:
    """The root of the worktree that holds directory, or empty."""
    try:
        return subprocess.run(["git", "-C", directory, "rev-parse", "--show-toplevel"], capture_output=True,
                              text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return ""


def project_root(cwd: str, project: str) -> str:
    """The tree targeted commands must stay in: the worktree of cwd when it belongs to the project's
    repository, else the project directory."""
    main = main_root(project)
    if main and main_root(cwd) == main:
        return toplevel(cwd) or cwd
    return toplevel(project) or project


def command_problem(command: Simple, dirs: set[str], forms: list[tuple], configured: list[list[str]],
                    root: str) -> str | None:
    """Why one simple command that runs a targeted runner is refused, or None (also for other commands)."""
    texts = [word.text for word in command.words]
    if texts in configured:
        return None
    index, dirs = unwrap(command.words, dirs)
    words = command.words[index:]
    rest = texts[index:]
    if not rest:
        return None
    program = os.path.basename(rest[0])
    if program in RUNNERS | ALL_SHELLS and runner_named(" ".join(rest[1:]), forms):
        return f"{program} runs a targeted runner the guard cannot check"
    found = match_form(rest)
    if found is None or found not in forms:
        return None
    if any(is_assignment(word) or os.path.basename(word.text) == "env" for word in command.words[:index]):
        return "variables set before it can change what the runner runs"
    if rest in configured:
        return None
    for directory in sorted(dirs):
        if not within(directory, root):
            return f"it runs in {directory}, outside the project"
    form, style, flags = found
    return (arguments_problem(style, flags, words[len(form_words(form)) :], dirs, root)
            or redirect_problem(command.targets, dirs, root))


def targeted_refuse(command: str, problem: str, forms: list[tuple]) -> None:
    """Refuse a targeted command, naming what is wrong and the runner forms."""
    shown = command if len(command) <= 200 else command[:200] + " ..."
    runners = ", ".join(sorted({" ".join(form_words(form[0])) for form in forms}))
    refuse(
        f"'{shown}' is refused: {problem}. A targeted command ({runners}) takes plain paths, packages and test"
        " patterns inside the project and the flags on its runner's safe list (README: Targeted commands);"
        " ask the owner to run it"
    )


def check_targeted(event: dict, cwd: str) -> None:
    """Refuse a Bash call that runs a runner of the project's "targeted" forms with an argument that is not
    a plain path, package or pattern inside the project, or a flag on that runner's safe list. A command
    line naming such a runner that is not plain is refused too. Only with "targeted" in .dev-loop.json."""
    if event.get("tool_name") != "Bash":
        return
    command = str((event.get("tool_input") or {}).get("command", ""))
    if not runner_named(command, TARGETED_FORMS):
        return
    try:
        project = os.environ.get("CLAUDE_PROJECT_DIR") or cwd
        config = load_config(project)
        forms = targeted_forms(config)
        if not forms or not runner_named(command, forms):
            return
        root = project_root(cwd, project)
        commands = PlainLexer(command).run()
        where, previous = Directories(cwd), ""
        configured = configured_argvs(config)
        for simple in commands:
            index, _ = unwrap(simple.words, where.dirs)
            texts = [word.text for word in simple.words[index:]]
            program = os.path.basename(texts[0]) if texts else ""
            if program in DIR_PROGRAMS:
                if "|" in {previous, simple.op}:
                    raise NotPlain(f"a {program} in a pipeline")
                where.change(program, simple.words[index + 1 :], previous)
            else:
                problem = command_problem(simple, where.dirs, forms, configured, root)
                if problem:
                    targeted_refuse(command, problem, forms)
            previous = simple.op
            where.after(simple.op)
    except NotPlain as error:
        targeted_refuse(command, f"it is not a plain command line ({error})", forms)
    except Exception as error:  # fail closed: a crash (exit 1) would let the command run unchecked
        if in_loop_project():
            refuse(f"cannot check this command against the targeted runners ({type(error).__name__}); ask the"
                   " owner to run it")


def read_event(raw: bytes) -> dict | None:
    """The PreToolUse event, or None when it is not a JSON object. An unreadable event (truncated, not
    UTF-8) is refused when its text names git and the project has .dev-loop.json: a hook that lets it pass
    would let an unchecked git command run."""
    try:
        event = json.loads(raw.decode("utf-8"))
    except ValueError:  # UnicodeDecodeError is one
        event = None
    if isinstance(event, dict):
        tool_input = event.get("tool_input")
        if tool_input is not None and not isinstance(tool_input, dict):
            event["tool_input"] = {"command": str(tool_input)}  # a string or list: read it as the command
        return event
    project = os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
    if text_names_git(raw.decode("utf-8", errors="replace")) and os.path.isfile(config_path(project)):
        refuse("cannot read this tool call (the hook event is not valid JSON) and it names git;"
               " ask the owner to run it")
    return None


def main() -> None:
    """Read the PreToolUse event and refuse what the scenario store and identity mode do not allow."""
    if sys.argv[1:2] == ["--scenarios-dir"]:
        cwd = sys.argv[2] if len(sys.argv) > 2 else os.getcwd()
        print(scenarios_dir(load_config(cwd), cwd))
        return
    if sys.argv[1:2] == ["--targeted-check"]:
        for entry in sys.argv[2:]:
            print(f"{entry}\t{targeted_refusal(entry)}")
        return
    raw = sys.stdin.buffer.read()
    try:
        event = read_event(raw)
        if event is not None:
            check_event(event, sys.argv[1:2] == ["--git-only"])
    except Exception as error:  # fail closed: a crash (exit 1) would let a git command run unchecked
        if raw_may_name_git(raw) and in_loop_project():
            refuse(f"cannot check this git command ({type(error).__name__}); ask the owner to run it")
        raise


def raw_may_name_git(raw: bytes) -> bool:
    """True when the raw event may name git: a plain text test that cannot fail on any input (a \\u escape
    or an ANSI-C string may spell it, so they count)."""
    text = raw.decode("utf-8", errors="replace").lower()
    return "git" in text or "\\u" in text or "$'" in text


def in_loop_project() -> bool:
    """True when the session's project has a .dev-loop.json (or DEV_LOOP_CONFIG names one); True when that
    cannot be told."""
    try:
        project = os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
        return os.path.isfile(os.environ.get("DEV_LOOP_CONFIG") or os.path.join(project, ".dev-loop.json"))
    except Exception:  # fail closed
        return True


def check_event(event: dict, git_only: bool) -> None:
    """Refuse what the scenario store, the git stop conditions and identity mode do not allow."""
    cwd = event.get("cwd") or os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
    check_targeted(event, cwd)
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
