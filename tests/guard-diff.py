"""Differential test of the git guard's shell parsing against bash (run by tests/smoke.sh, python3 -I).

Each case is a shell text followed by a newline and `git push origin main`. Bash runs it with a stub `git`
first on an otherwise empty PATH (so nothing but builtins and the stub can run); whenever bash runs the stub
with `push origin main`, the guard must refuse the text. A fixed corpus plus a seeded random generator, so
the run is deterministic. Prints one line per miss and a summary; exits 1 on any miss.

Usage: guard-diff.py GUARD_PY WORK_DIR [RANDOM_CASES]
"""

import importlib.util
import os
import random
import subprocess
import sys

TAIL = "\ngit push origin main"
# Fragments of shell syntax the guard must read as bash does (no redirection to files, no cd, no names of
# real programs: with PATH set to the stub directory only, any other word is "command not found").
FRAGMENTS = [
    "echo ", "a", "x", " ", "'", '"', "\\", "\\\\", "$'", "\\'", "$(", ")", "(", "`", "<<E", "<<'E'", "<<-E",
    "\nE", "\n", "#", ";", "&&", "|", "\\\n", "$((1<<2))", "{ ", " }", "\t", "E",
]
CORPUS = [
    "echo a", "echo 'a'", 'echo "a"', "echo a\\", "echo a\\\\", "echo a \\\\", "echo a\\\\\\", "echo $'a\\'b'",
    "echo $'\\''", "echo $'a\\\\'", "echo \"$'\"", "echo '$'", "echo \"a\\\"b\"", "echo 'a\\'", "echo `echo a`",
    "echo $(echo a)", "echo \"$(echo ')')\"", "echo # it's", "echo a#b", "echo '#'", "echo \\#", "echo <<E\nx\nE",
    "echo <<'E'\nx\nE", "echo <<\"E\"\na\nE", "echo <<-E\n\tx\n\tE", "echo \"<<E\"", "echo '<<E'", "echo \\<<E",
    "echo $((1<<2))", "echo $'<<E'", "echo $'\\n'", "echo $'a\\\nb'", "echo \"a\\\nb\"", "echo 'a\\\nb'",
    "echo a\\\nb", "echo a \\\n b", "# comment \\", "echo a # \\", "echo \"$(echo \"a\")\"", "echo `echo '`'`",
    "echo $(echo $'\\'')", "echo \"`echo a`\"", "{ echo a; }", "(echo a)", "echo a; echo b", "echo a && echo b",
    "echo a | echo b", "echo a;", "echo a\\;", "echo 'a;b'", "echo $'a;b'", "echo <<E; echo b\nx\nE",
    "echo <<E <<F\nx\nE\ny\nF", "echo <<E\n$(echo a)\nE", "echo <<E\n`echo a`\nE", "echo \"a'b\"", "echo 'a\"b'",
    "echo $'a\"b'", "echo \"\\\\\"", "echo a\\\\\nb", "echo $'\\x41'", "echo $'\\101'", "echo $'\\u0041'",
    "echo ${x:-a}", "echo \"${x:-a}\"", "echo $\"a\"", "echo a\\ b", "echo '' \"\"", "echo $''", "echo \\$'a'",
]


def load_guard(path: str):
    """The guard module, loaded from its file (it is a script, not a package)."""
    spec = importlib.util.spec_from_file_location("guard_role", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def random_cases(count: int) -> list[str]:
    """count shell texts of 1 to 8 random fragments (seeded, so every run is the same)."""
    rng = random.Random(71)
    return ["".join(rng.choice(FRAGMENTS) for _ in range(rng.randint(1, 8))) for _ in range(count)]


def bash_pushes(text: str, work: str) -> bool:
    """True when bash, given text, runs the stub git with `push origin main`."""
    log = os.path.join(work, "git.log")
    if os.path.exists(log):
        os.remove(log)
    env = {"PATH": os.path.join(work, "stub"), "GIT_STUB_LOG": log, "HOME": work}
    try:
        subprocess.run(["/bin/bash", "-c", text], cwd=work, env=env, stdin=subprocess.DEVNULL,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
    except subprocess.TimeoutExpired:
        return False
    if not os.path.exists(log):
        return False
    with open(log, encoding="utf-8", errors="replace") as handle:
        return "push origin main" in handle.read().splitlines()


def guard_refuses(guard, text: str, work: str) -> bool:
    """True when the guard's git check (the fast path included) refuses text."""
    event = {"tool_name": "Bash", "tool_input": {"command": text}}
    if not guard.names_git(event):
        return False
    stderr = sys.stderr
    sys.stderr = open(os.devnull, "w")
    try:
        guard.check_git_stop_conditions(event, {"base_branch": "main"}, work)
    except SystemExit as stop:
        return stop.code == 2
    finally:
        sys.stderr.close()
        sys.stderr = stderr
    return False


def write_stub(work: str) -> None:
    """A `git` that only records its arguments."""
    stub = os.path.join(work, "stub")
    os.makedirs(stub, exist_ok=True)
    path = os.path.join(stub, "git")
    with open(path, "w", encoding="utf-8") as handle:
        handle.write('#!/bin/bash\nIFS=" "; echo "$*" >>"$GIT_STUB_LOG"\n')
    os.chmod(path, 0o755)


def make_repo(work: str) -> str:
    """A throwaway repository for the guard to run in (its tag lookups need one)."""
    repo = os.path.join(work, "repo")
    subprocess.run(["git", "init", "-q", repo], check=True)
    return repo


def main() -> None:
    """Run every case through bash and the guard; report each push bash runs that the guard lets pass."""
    guard = load_guard(sys.argv[1])
    work = sys.argv[2]
    count = int(sys.argv[3]) if len(sys.argv) > 3 else 300
    write_stub(work)
    repo = make_repo(work)
    misses, pushes, cases = [], 0, CORPUS + random_cases(count)
    for case in cases:
        text = case + TAIL
        if not bash_pushes(text, work):
            continue
        pushes += 1
        try:
            refused = guard_refuses(guard, text, repo)
        except Exception as error:  # a crash is a miss: the hook would exit 1 and let the call run
            refused = False
            text += f"  [{type(error).__name__}: {error}]"
        if not refused:
            misses.append(text)
    for text in misses:
        print(f"MISS {text!r}")
    print(f"guard-diff: {len(cases)} cases, {pushes} where bash pushes, {len(misses)} let through")
    sys.exit(1 if misses else 0)


if __name__ == "__main__":
    main()
