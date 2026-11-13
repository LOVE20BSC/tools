#!/usr/bin/env python3
"""BatchTransfer deployment regression checks.

The repository holds exactly one deployable tool, so every check here is about BatchTransfer's
`script/deploy/` module and the network files it reads.

Two halves, no network and no broadcast:

- structural checks against the real repository (shared params.sh hash, per-network profiles,
  declared dependencies, script permissions, no hardcoded addresses, verifier opt-out list);
- behavioural checks inside a throwaway project root, where fake cast/forge/osascript/mktemp
  executables log every call and let each failure path be exercised deterministically.

The behavioural half reuses the step scripts verbatim (copied into the temp root), so a regression
in loading, key-set assertion, credential handling or atomic address writing fails here.
"""
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

# Any step writing this into stdout/stderr counts as a regression.
SECRET_PASSWORD = "do-not-print-this-password"

# params.sh is one byte-identical copy per repository (core/action/group-chat/dex, and now tools):
# every repo must stay deployable on its own, so the file cannot be shared and this constant is the
# only thing stopping drift. Changing the file means changing all five copies and this hash.
PARAMS_SH_SHA256 = "b3a8f64dc87d9e823a364de92e3bc79144d246f1c1a861cdcf95616042b8f840"

ZERO_ADDRESS = "0x0000000000000000000000000000000000000000"
ADDRESS_VALUE = re.compile(r"0x[0-9a-fA-F]{40}")
KEY_LINE = re.compile(r"^([A-Z][A-Z0-9_]*)=(.*)$", re.MULTILINE)
# UPPER_SNAKE_CASE: no leading/trailing/double underscore, digits stay inside their word.
UPPER_SNAKE = re.compile(r"^[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)*$")


def repo_root() -> Path:
    return Path(__file__).resolve().parents[1]


def code_lines(text: str) -> str:
    """Drop comment-only lines: a marker inside a comment must not satisfy a structural assertion."""
    return "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))


def network_dirs() -> list:
    return sorted(path for path in (repo_root() / "script/network").iterdir() if path.is_dir())


def tool_modules(directory: Path) -> list:
    """Modules of one network directory: every addresses.<module>.params it carries.

    tools is a zero-dependency repository: every address file belongs to a module of this repository
    and has a matching <module>.params next to it, so the file name alone is the module list. Adding
    a tool means adding its pair of files; nothing here needs to know the tool's name.
    """
    return sorted(path.name[len("addresses."):-len(".params")]
                  for path in directory.glob("addresses.*.params"))


def all_address_files(directory: Path) -> list:
    return sorted(directory.glob("addresses.*.params"))


def address_key(module: str) -> str:
    """batch-transfer -> BATCH_TRANSFER_ADDRESS (dev-standards §6.2)."""
    return module.upper().replace("-", "_") + "_ADDRESS"


# --------------------------------------------------------------------------------------------
# Structural checks over the real repository.
# --------------------------------------------------------------------------------------------


def params_shared_copy() -> None:
    """params.sh must stay byte-identical to the other repositories' copies."""
    digest = hashlib.sha256((repo_root() / "script/deploy/params.sh").read_bytes()).hexdigest()
    assert digest == PARAMS_SH_SHA256, (
        "script/deploy/params.sh drifted from the shared copy (sha256 " + digest + "); "
        "apply the change to core / action / group-chat / dex as well"
    )


def params_loader_cases() -> None:
    """params.sh expands 1e17 / 1_000_000, drops trailing comments and keeps quoted '#'."""
    cases = [
        ("A=1e17\n", "100000000000000000"),
        ("A=3e15  # 0.30%\n", "3000000000000000"),
        ("A=1_000\n", "1000"),
        ('A="a # b"\n', "a # b"),
        ("A=x1e5y\n", "x1e5y"),
    ]
    with tempfile.TemporaryDirectory(prefix="params-loader-test-") as directory:
        path = Path(directory) / "case.params"
        for text, expected in cases:
            path.write_text(text)
            result = subprocess.run(
                ["bash", "-c", '. "$1"; params_load "$2"; printf "%s" "$A"',
                 "bash", str(repo_root() / "script/deploy/params.sh"), str(path)],
                text=True, capture_output=True)
            assert result.returncode == 0, (text, result.stderr)
            assert result.stdout == expected, (text, result.stdout)


def params_unset_coverage() -> None:
    """Every step that sources params.sh must sweep inherited values before the first load, and the
    sweep must cover every file the step loads."""
    scripts = sorted((repo_root() / "script/deploy").glob("*.sh"))
    assert scripts
    for script in scripts:
        text = script.read_text()
        if 'source "$SCRIPT_DIR/params.sh"' not in text:
            continue
        code = code_lines(text)
        assert "params_unset_all " in code, script
        assert code.index("params_unset_all ") < code.index("params_load "), script
        # Rejoin continuation lines first, otherwise only the first argument is visible.
        joined = code.replace("\\\n", " ")
        statement = re.search(r"params_unset_all(.*)", joined).group(1).split("\n")[0]
        unset_files = set(re.findall(r'"([^"]+)"', statement))
        load_files = set(re.findall(r'params_load\s+"([^"]+)"', joined))
        assert not load_files - unset_files, (script, load_files - unset_files)


def network_profiles() -> None:
    """Every network directory carries the full file set, and its address file matches the module."""
    networks = network_dirs()
    assert networks, "script/network/ has no network directory"
    for directory in networks:
        assert (directory / "network.params").is_file(), directory
        modules = tool_modules(directory)
        assert modules, f"{directory} declares no addresses.<module>.params"
        # tools holds exactly one tool today; the assertion is on the set, not on the count, so
        # adding a tool keeps working as long as it ships both files.
        assert "batch-transfer" in modules, (directory, modules)
        for module in modules:
            # No copied dependency address file can exist here: tools is zero-dependency, so a
            # missing <module>.params is a real error, not a cross-repository import.
            assert (directory / f"{module}.params").is_file(), (directory, module)
            address_file = directory / f"addresses.{module}.params"
            text = address_file.read_text()
            keys = [key for key, _ in KEY_LINE.findall(text)]
            expected = address_key(module)
            assert keys == [expected], (address_file, keys, expected)
            assert UPPER_SNAKE.fullmatch(expected), expected
            assert expected.endswith("_ADDRESS"), expected
            value = KEY_LINE.search(text).group(2).strip()
            # Empty sentinel means "not deployed yet"; anything else must be a real address.
            assert value == "" or ADDRESS_VALUE.fullmatch(value), (address_file, value)
            assert value != ZERO_ADDRESS, (address_file, "zero address is not a valid sentinel here")


def dependencies_are_declared() -> None:
    """Only submodules the source actually imports may be declared and remapped.

    tools is a zero-dependency repository: every import is either local or `@forge-std/`. A declared
    submodule or remapping that no source uses is dead weight that hides real dependencies in a
    `.gitmodules` diff, so the two lists are checked against each other and against the imports.
    """
    root = repo_root()
    declared = sorted(re.findall(r'^\[submodule "lib/([^"]+)"\]',
                                 (root / ".gitmodules").read_text(), re.MULTILINE))
    # foundry.lock keys are repository-relative paths ("lib/forge-std"); compare without the prefix.
    locked = sorted(key[len("lib/"):] for key in json.loads((root / "foundry.lock").read_text()))
    assert declared == locked, (declared, locked)
    # Foundry's own dependency, always present: forge-std is what the tests and deploy script import.
    assert declared == ["forge-std"], declared
    remaps = sorted(line for line in (root / "remappings.txt").read_text().splitlines() if line.strip())
    assert remaps == ["@forge-std/=lib/forge-std/src/"], remaps
    # And no source reaches for a remapping that is not declared: `auto_detect_remappings = false`.
    for source in sorted((root / "src").rglob("*.sol")) + sorted((root / "test").rglob("*.sol")) \
            + sorted((root / "script").rglob("*.sol")):
        for imported in re.findall(r'import\s+\{[^}]*\}\s+from\s+"([^"]+)"', source.read_text()):
            assert imported.startswith(("@forge-std/", "../", "./")), (source, imported)


def network_params_keys() -> None:
    """network.params must carry CHAIN_ID and RPC_URL as non-empty values."""
    for directory in network_dirs():
        text = (directory / "network.params").read_text()
        for key in ("CHAIN_ID", "RPC_URL"):
            match = re.search(rf"^{key}=(.*)$", text, re.MULTILINE)
            assert match, (directory / "network.params", key)
            assert match.group(1).strip(), (directory / "network.params", key)


def scripts_stay_within_bash_32() -> None:
    """No script may use a bash-4-only construct.

    macOS still ships bash 3.2 as /bin/bash and the scripts run under `#!/usr/bin/env bash`, so a
    bash-4 expansion is not a portability nicety — it is a runtime failure. The dangerous ones fail
    *inside* a command substitution, which turns an assertion into a comparison of two empty
    strings that reports success while checking nothing (`script/e2e/anvil_e2e.sh` shipped that bug
    once). `bash -n` does not catch it because the construct parses fine and only fails at
    expansion time, so guard it statically.
    """
    # The parameter name may be a positional or a special parameter too: the bug this guards
    # against was `${1,,}`, which an identifier-only class would miss. `1, @, *, #, ?, $, !, -` are
    # all legal there.
    bash4_only = re.compile(
        r"\$\{[0-9@*#?!$-]+(,,|\^\^)"                                   # positional/special case conversion
        r"|\$\{[A-Za-z_][A-Za-z0-9_]*(\[[^\]]*\])?(,,|\^\^)"          # named case conversion
        r"|\bdeclare\s+-A\b"                                           # associative arrays
        r"|\b(mapfile|readarray)\b"                                     # array readers
        r"|\[\[\s+-v\s"                                               # -v test
    )
    for script in sorted((repo_root() / "script").rglob("*.sh")):
        # Strip comments first: the helper documents the very construct it forbids, and scanning
        # the raw text would flag that explanation as a violation.
        code = "\n".join(
            line for line in script.read_text().splitlines() if not line.lstrip().startswith("#")
        )
        offenders = bash4_only.findall(code)
        assert not offenders, f"{script} uses bash-4-only syntax: {offenders}"


def e2e_script_structure() -> None:
    """Structural guard for `script/e2e/anvil_e2e.sh`.

    The end-to-end script cannot run here — it needs anvil — so this only pins the properties that a
    silent regression would break without any test noticing: the file is executable, it parses under
    the shell that macOS ships, it drives the deploy entry points rather than re-implementing
    deployment, and it restores the files it rewrites.

    Three real defects reached a green run through this gap before it existed: a bash-4 expansion that
    made an assertion compare two empty strings, and a cleanup trap whose signal handler resumed the
    script. The first is caught by `scripts_stay_within_bash_32`; the second by the `exit` requirement
    below.
    """
    script = repo_root() / "script/e2e/anvil_e2e.sh"
    assert script.is_file(), script
    assert "set -euo pipefail" in script.read_text(), script
    assert os.access(script, os.X_OK), f"{script} is not executable"

    # Strip comments: the guard would otherwise be satisfied by writing the expected strings into a
    # comment, which would prove nothing about the code path.
    text = code_lines(script.read_text())
    # Drives the real entry points instead of a parallel deployment implementation.
    for entry in ("one_click_deploy_batch_transfer.sh",):
        assert entry in text, f"{script} does not drive {entry}"
    # Restores every file it rewrites, including the network config it repoints.
    assert "BACKUP_DIR" in text and "network.params" in text, script
    # A signal trap that only runs cleanup resumes the script; each one has to exit. Check both
    # signals separately: matching the shared prefix would still pass if one of them regressed.
    for signal, code in (("INT", "130"), ("TERM", "143")):
        expected = f"trap 'cleanup; exit {code}' {signal}"
        assert expected in text, f"{script} does not terminate on {signal} (expected: {expected})"

    # `bash -n` under the system shell catches syntax errors the e2e run would only hit on execution.
    for shell in ("/bin/bash", "/bin/sh"):
        if not os.path.exists(shell):
            continue
        result = subprocess.run([shell, "-n", str(script)], capture_output=True, text=True)
        assert result.returncode == 0, (shell, result.stderr)


def scripts_have_shebang_and_exec_bit() -> None:
    """Every deploy script is a bash script; every step/entry script is executable.

    params.sh is the exception: it is sourced, never executed, and all five repositories keep it at
    mode 100644 so the copies stay comparable.
    """
    for script in sorted((repo_root() / "script/deploy").glob("*.sh")):
        text = script.read_text()
        assert text.startswith("#!/usr/bin/env bash\n"), script
        executable = os.access(script, os.X_OK)
        if script.name == "params.sh":
            continue
        assert executable, f"{script} is not executable (chmod +x)"
        # A step that runs under `set -euo pipefail` must not silently continue on errors.
        assert "set -euo pipefail" in text, script


def deploy_script_has_no_hardcoded_address() -> None:
    """Deployment addresses come from files only; the zero address is the sole allowed literal."""
    for name in ("DeployBatchTransfer.s.sol",):
        source = (repo_root() / "script/deploy" / name).read_text()
        literals = set(ADDRESS_VALUE.findall(source))
        assert literals <= {ZERO_ADDRESS}, (name, sorted(literals))


def deploy_script_structure() -> None:
    """The Foundry script keeps the §6.3 shape: load -> validate -> broadcast -> validate."""
    source = (repo_root() / "script/deploy/DeployBatchTransfer.s.sol").read_text()
    for function in ("_loadConfig", "_validateConfig", "_validateDeployment"):
        assert f"function {function}(" in source, function
    body = source.index("function run()")
    start = source.index("vm.startBroadcast()", body)
    stop = source.index("vm.stopBroadcast()", body)
    assert body < start < stop, "run() must broadcast between the two validation phases"
    # The static validation must finish before anything is broadcast.
    assert source.index("_validateConfig(config)", body) < start, "static checks must precede the broadcast"
    assert source.index("_validateDeployment(", body) > stop, "the binding graph is read back after the broadcast"
    # BatchTransfer takes no constructor arguments: no module parameter may be read.
    assert "vm.envAddress" not in source and "vm.envString" not in source, (
        "BatchTransfer has no constructor parameters; a parameter read means the design changed")
    assert "BATCH_TRANSFER_ADDRESS=" in source, "the summary line 11_deploy_batch_transfer.sh greps is missing"


MODULES = {
    "batch-transfer": {
        "entrypoint": "one_click_deploy_batch_transfer.sh",
        "steps": ("11_deploy_batch_transfer.sh", "21_check_batch_transfer.sh", "31_verify_batch_transfer.sh"),
    },
}


def entrypoint_is_orchestration_only() -> None:
    """Each entrypoint sources nothing and only calls its own step scripts; steps load their inputs."""
    deploy = repo_root() / "script/deploy"
    for module, spec in MODULES.items():
        entrypoint = deploy / spec["entrypoint"]
        assert entrypoint.is_file(), entrypoint
        lines = [line.strip() for line in code_lines(entrypoint.read_text()).splitlines() if line.strip()]
        assert not [line for line in lines if line.startswith("source ")], (
            f"{spec['entrypoint']} must not source any file")
        for step in spec["steps"]:
            assert any(step in line for line in lines), (entrypoint, step)
            assert 'source "$SCRIPT_DIR/params.sh"' in (deploy / step).read_text(), step
        # Steps never call each other: sequencing belongs to the entrypoint only.
        for step in spec["steps"]:
            text = code_lines((deploy / step).read_text())
            others = [other for other in spec["steps"] if other != step]
            assert not any(other in text for other in others), (step, "a step must not call another step")
        # And no step of one module reaches into another module's entrypoint or steps.
        for other_module, other_spec in MODULES.items():
            if other_module == module:
                continue
            for step in spec["steps"]:
                text = code_lines((deploy / step).read_text())
                assert other_spec["entrypoint"] not in text, (step, other_spec["entrypoint"])


def verifier_skip_never_production() -> None:
    """Production chains may not opt out of source verification."""
    profile = repo_root() / "script/network/verifier.params"
    assert profile.is_file(), "script/network/verifier.params is missing"
    text = profile.read_text()
    url = re.search(r"^ETHERSCAN_VERIFIER_URL=(.*)$", text, re.MULTILINE)
    skip = re.search(r"^VERIFY_SKIP_CHAIN_IDS=(.*)$", text, re.MULTILINE)
    assert url and url.group(1).strip(), (profile, "ETHERSCAN_VERIFIER_URL is empty")
    assert skip, (profile, "VERIFY_SKIP_CHAIN_IDS is missing")
    skipped = {item.strip() for item in skip.group(1).split(",") if item.strip()}
    assert not skipped & {"56", "97"}, (profile, sorted(skipped))


# --------------------------------------------------------------------------------------------
# Behavioural checks: fake cast/forge in a throwaway project root.
# --------------------------------------------------------------------------------------------


def fake_tool(tool: str, args: list) -> int:
    data = json.loads(Path(os.environ["MOCK_DATA"]).read_text())
    with Path(os.environ["MOCK_LOG"]).open("a") as log:
        log.write(json.dumps([tool, *args]) + "\n")
    if tool == "osascript":
        print("test-password")
    elif tool == "mktemp":
        fd, path = tempfile.mkstemp(dir=os.environ["MOCK_TMP"])
        os.close(fd)
        print(path)
    elif tool == "cast":
        if args[0] == "chain-id":
            print(os.environ.get("RPC_CHAIN", data["chain_id"]))
        elif args[0] == "code":
            if os.environ.get("RPC_CODE_ERROR"):
                return 1
            print(os.environ.get("MOCK_CODE", data["code"]))
        else:
            raise AssertionError(args)
    elif tool == "forge":
        if args[0] == "script":
            # The contract has no constructor parameters: no --sig argument beyond run(), no
            # --constructor-args, and the keystore password only through a 600 temp file.
            assert args[1] == "script/deploy/DeployBatchTransfer.s.sol:DeployBatchTransfer", args
            assert "--password" not in args, "CREDENTIAL_IN_ARGV"
            password_file = args[args.index("--password-file") + 1] if "--password-file" in args else None
            if not password_file or not Path(password_file).is_file():
                print("PASSWORD_FILE_MISSING", file=sys.stderr)
            else:
                mode = os.stat(password_file).st_mode & 0o777
                print(f"PASSWORD_SHA={hashlib.sha256(Path(password_file).read_bytes()).hexdigest()}",
                      file=sys.stderr)
                print(f"PASSWORD_MODE={mode:o}", file=sys.stderr)
            if os.environ.get("DEPLOY_FAIL"):
                return 1
            # A successful broadcast refreshes run-latest.json's timestamp; a missing file is not
            # recreated, so STALE_BROADCAST can simulate an artifact from an earlier run.
            broadcast = os.environ.get("MOCK_BROADCAST")
            if broadcast and Path(broadcast).exists():
                artifact = json.loads(Path(broadcast).read_text())
                artifact["timestamp"] = 0 if os.environ.get("STALE_BROADCAST") else int(time.time() * 1000)
                Path(broadcast).write_text(json.dumps(artifact, indent=2))
            if not os.environ.get("OMIT_ADDRESS"):
                print("\n=== Deployment Summary ===")
                # Real forge prints "KEY= 0x...", the script must tolerate the space.
                print("BATCH_TRANSFER_ADDRESS= " + data["address"])
        elif args[0] == "verify-contract":
            if os.environ.get("VERIFY_FAIL"):
                return 1
        else:
            raise AssertionError(args)
    else:
        raise AssertionError(args)
    return 0


def behavioural_checks() -> int:
    checks = 0
    with tempfile.TemporaryDirectory(prefix="tools-deploy-test-") as directory:
        root = Path(directory)
        deploy = root / "script/deploy"
        shutil.copytree(repo_root() / "script/deploy", deploy)
        network = root / "script/network/test"
        network.mkdir(parents=True)
        (root / "script/network/verifier.params").write_text(
            "ETHERSCAN_VERIFIER_URL=https://api.etherscan.io/v2/api\nVERIFY_SKIP_CHAIN_IDS=31337\n")
        bin_dir = root / "bin"
        bin_dir.mkdir()
        for tool in ("cast", "forge", "osascript", "mktemp"):
            stub = bin_dir / tool
            stub.write_text("#!/bin/sh\nexec " + shlex.quote(sys.executable) + " "
                            + shlex.quote(str(Path(__file__).resolve())) + " --fake " + tool + ' "$@"\n')
            stub.chmod(0o755)
        tmp_dir = root / "tmp"
        tmp_dir.mkdir()
        deployed = "0x" + "ab" * 20
        data_path, log_path = root / "rpc.json", root / "calls.log"
        runtime_code = "0x" + "60" * 100
        data_path.write_text(
            json.dumps({"chain_id": "31337", "address": deployed, "code": runtime_code}))
        # `21_check` compares the deployed code against the local build artifact, so the throwaway root
        # needs one to compare against.
        artifact = root / "out/BatchTransfer.sol/BatchTransfer.json"
        artifact.parent.mkdir(parents=True)
        artifact.write_text(json.dumps({"deployedBytecode": {"object": runtime_code}}))
        network.joinpath("network.params").write_text("CHAIN_ID=31337\nRPC_URL=http://invalid.local\n")
        network.joinpath("batch-transfer.params").write_text("# BatchTransfer has no constructor parameters\n")
        address_file = network / "addresses.batch-transfer.params"
        address_file.write_text("BATCH_TRANSFER_ADDRESS=\n")
        broadcast = root / "broadcast/DeployBatchTransfer.s.sol/31337/run-latest.json"
        broadcast.parent.mkdir(parents=True)
        broadcast.write_text(json.dumps({"transactions": [], "timestamp": 0}, indent=2))
        base = {"PATH": str(bin_dir) + os.pathsep + os.environ["PATH"], "MOCK_DATA": str(data_path),
                "MOCK_LOG": str(log_path), "MOCK_BROADCAST": str(broadcast), "MOCK_TMP": str(tmp_dir)}

        def run(script, success=True, args=("test",), **extra):
            nonlocal checks
            log_path.write_text("")
            result = subprocess.run(["bash", str(deploy / script), *args], env={**base, **extra},
                                    cwd=root, text=True, capture_output=True)
            output = result.stdout + result.stderr
            assert (result.returncode == 0) == success, (script, extra, result.stdout, result.stderr)
            assert SECRET_PASSWORD not in output, output
            for marker in ("CREDENTIAL_IN_ARGV", "PASSWORD_FILE_MISSING"):
                assert marker not in output, (marker, output)
            log = [json.loads(line) for line in log_path.read_text().splitlines()]
            # The password file is always removed, whether the run succeeded or failed.
            for call in log:
                if call[:2] == ["forge", "script"] and "--password-file" in call:
                    assert not Path(call[call.index("--password-file") + 1]).exists(), call
            checks += 1
            return result, log

        def write_account(password_line=""):
            network.joinpath(".account").write_text(
                "KEYSTORE_ACCOUNT=test-keystore\nACCOUNT_ADDRESS=0x" + "f5" * 20 + "\n" + password_line)

        def collect_kept_log(output: str) -> None:
            """Post-broadcast failures keep the deploy log for manual recovery; assert it, then drop it."""
            assert "Deployment log:" in output, output
            kept_log = Path(output.split("Deployment log:", 1)[1].splitlines()[0].strip())
            assert kept_log.exists(), kept_log
            kept_log.unlink()

        write_account()

        # 1. Empty sentinel: the check fails before any chain call.
        result, log = run("21_check_batch_transfer.sh", False)
        output = result.stdout + result.stderr
        assert "missing or invalid" in output, output
        assert "run one_click_deploy_batch_transfer.sh first" in output, output
        assert not any(call[:2] == ["cast", "call"] for call in log), log

        # 2. Zero address is rejected the same way.
        address_file.write_text(f"BATCH_TRANSFER_ADDRESS={ZERO_ADDRESS}\n")
        result, _ = run("21_check_batch_transfer.sh", False)
        assert "missing or invalid" in result.stdout + result.stderr, result.stdout + result.stderr

        # 3. A renamed or extra key fails the key-set assertion, not a later chain call.
        address_file.write_text(f"BATCHTRANSFER_ADDRESS={deployed}\n")
        result, _ = run("21_check_batch_transfer.sh", False)
        assert "key set mismatch" in result.stdout + result.stderr, result.stdout + result.stderr
        address_file.write_text(f"BATCH_TRANSFER_ADDRESS={deployed}\nEXTRA_ADDRESS={deployed}\n")
        result, _ = run("21_check_batch_transfer.sh", False)
        assert "key set mismatch" in result.stdout + result.stderr, result.stdout + result.stderr

        # 4. Happy path: deployed and chain matches. The contract no longer exposes a deployment-time
        # constant (the per-recipient gas budget is a call argument), so there is no value to read
        # back; the step's job is deployment identity plus the address-file key set.
        address_file.write_text(f"BATCH_TRANSFER_ADDRESS={deployed}\n")
        result, log = run("21_check_batch_transfer.sh")
        output = result.stdout + result.stderr
        assert "BatchTransfer verified" in output, output
        assert any(call[:2] == ["cast", "code"] for call in log), log
        assert not any(call[:2] == ["cast", "call"] for call in log), log

        # 5. Each on-chain mismatch fails on its own.
        result, _ = run("21_check_batch_transfer.sh", False, RPC_CODE_ERROR="1")
        assert "not deployed" in result.stdout + result.stderr, result.stdout + result.stderr
        # Code presence alone would accept any contract at the address; the hash has to differ too.
        result, _ = run("21_check_batch_transfer.sh", False, MOCK_CODE="0x" + "61" * 100)
        assert "does not match the local build" in result.stdout + result.stderr, result.stdout + result.stderr
        result, _ = run("21_check_batch_transfer.sh", False, RPC_CHAIN="56")
        assert "chain ID" in result.stdout + result.stderr, result.stdout + result.stderr

        # 6. Missing configuration fails loudly instead of continuing with an empty value.
        params_file = network / "batch-transfer.params"
        params_file.unlink()
        result, _ = run("21_check_batch_transfer.sh", False)
        assert "batch-transfer.params" in result.stdout + result.stderr, result.stdout + result.stderr
        params_file.write_text("# BatchTransfer has no constructor parameters\n")

        # 7. Deploy: writes the address file atomically, never passes --password, and removes the
        #    password temp file (already asserted in run()).
        address_file.write_text("BATCH_TRANSFER_ADDRESS=\n")
        result, log = run("11_deploy_batch_transfer.sh")
        output = result.stdout + result.stderr
        assert address_file.read_text() == f"BATCH_TRANSFER_ADDRESS={deployed}\n", address_file.read_text()
        command = next(call for call in log if call[:2] == ["forge", "script"])
        assert command[command.index("--chain-id") + 1] == "31337", command
        assert command[command.index("--account") + 1] == "test-keystore", command
        assert command[command.index("--sender") + 1] == "0x" + "f5" * 20, command
        assert "--unlocked" not in command and "--private-key" not in command, command
        assert command[command.index("--sig") + 1] == "run()", command
        # Prompted once (no password in .account), and the temp file is 600.
        assert "PASSWORD_SHA=" + hashlib.sha256(b"test-password").hexdigest() in output, output
        assert "PASSWORD_MODE=600" in output, output
        assert len([call for call in log if call[0] == "osascript"]) == 1, log

        # 8. A configured password is used directly: no prompt.
        write_account("KEYSTORE_PASSWORD=" + SECRET_PASSWORD + "\n")
        result, log = run("11_deploy_batch_transfer.sh")
        assert "PASSWORD_SHA=" + hashlib.sha256(SECRET_PASSWORD.encode()).hexdigest() in result.stdout + result.stderr
        assert not any(call[0] == "osascript" for call in log), log

        # 9. An explicit empty password line counts as "not configured".
        write_account("KEYSTORE_PASSWORD=\n")
        result, log = run("11_deploy_batch_transfer.sh")
        assert len([call for call in log if call[0] == "osascript"]) == 1, log
        write_account()

        # 10. A broadcast artifact from an earlier run is refused: the address file must not move.
        saved = address_file.read_text()
        result, _ = run("11_deploy_batch_transfer.sh", False, STALE_BROADCAST="1")
        output = result.stdout + result.stderr
        assert "was not updated by this deployment" in output, output
        collect_kept_log(output)
        assert address_file.read_text() == saved, address_file.read_text()

        # 11. Missing address line in the deploy log: no half-written file.
        result, _ = run("11_deploy_batch_transfer.sh", False, OMIT_ADDRESS="1")
        output = result.stdout + result.stderr
        assert "BATCH_TRANSFER_ADDRESS" in output, output
        collect_kept_log(output)
        assert address_file.read_text() == saved, address_file.read_text()

        # 12. Broadcast failure keeps the log path for manual recovery and leaves the file alone.
        result, _ = run("11_deploy_batch_transfer.sh", False, DEPLOY_FAIL="1")
        output = result.stdout + result.stderr
        assert "may already be on chain" in output, output
        collect_kept_log(output)
        assert address_file.read_text() == saved, address_file.read_text()

        # 13. .account without KEYSTORE_ACCOUNT / ACCOUNT_ADDRESS: fail before broadcasting.
        network.joinpath(".account").write_text("UNRELATED=x\n")
        run("11_deploy_batch_transfer.sh", False)
        network.joinpath(".account").unlink()
        run("11_deploy_batch_transfer.sh", False)
        write_account()

        # 14. A failed atomic write must not truncate the previous record (same-dir temp + mv).
        if os.geteuid() != 0:
            network.chmod(0o555)
            try:
                result, _ = run("11_deploy_batch_transfer.sh", False)
            finally:
                network.chmod(0o755)
            output = result.stdout + result.stderr
            assert "may already be on chain" in output, output
            assert address_file.read_text() == saved, address_file.read_text()
            collect_kept_log(output)

        # 15. The entrypoint restores the previous address when the post-deploy check fails.
        address_file.write_text("# previous deployment\n")
        # The contract no longer exposes a deployment-time constant, so the only ways the post-deploy
        # check can fail are a wrong chain and a failed deployment.
        for extra in ({"RPC_CHAIN": "56"}, {"DEPLOY_FAIL": "1"}):
            result, _ = run("one_click_deploy_batch_transfer.sh", False, **extra)
            assert address_file.read_text() == "# previous deployment\n", address_file.read_text()
            output = result.stdout + result.stderr
            if "Deployment log:" in output:
                collect_kept_log(output)

        # 16. Entrypoint happy path: deploy + check, then the verify step skips chain 31337.
        result, log = run("one_click_deploy_batch_transfer.sh")
        output = result.stdout + result.stderr
        assert address_file.read_text() == f"BATCH_TRANSFER_ADDRESS={deployed}\n", address_file.read_text()
        assert "Skip: source verification" in output, output
        assert not any(call[:2] == ["forge", "verify-contract"] for call in log), log
        assert "Deployment completed" in output, output

        # 17. Off the skip list the same chain is verified, and a verification failure propagates.
        (root / "script/network/verifier.params").write_text(
            "ETHERSCAN_VERIFIER_URL=https://api.etherscan.io/v2/api\nVERIFY_SKIP_CHAIN_IDS=\n")
        network.joinpath("network.params").write_text(
            "CHAIN_ID=31337\nRPC_URL=http://invalid.local\nETHERSCAN_API_KEY=test-key\n")
        _, log = run("31_verify_batch_transfer.sh")
        verify_calls = [call for call in log if call[:2] == ["forge", "verify-contract"]]
        assert len(verify_calls) == 1, log
        assert verify_calls[0][2] == deployed, verify_calls[0]
        assert verify_calls[0][3] == "src/BatchTransfer.sol:BatchTransfer", verify_calls[0]
        assert "--constructor-args" not in verify_calls[0], verify_calls[0]
        run("31_verify_batch_transfer.sh", False, VERIFY_FAIL="1")

        # 18. A missing API key fails before any verification request is sent.
        network.joinpath("network.params").write_text("CHAIN_ID=31337\nRPC_URL=http://invalid.local\n")
        result, log = run("31_verify_batch_transfer.sh", False)
        assert "ETHERSCAN_API_KEY" in result.stdout + result.stderr, result.stdout + result.stderr
        assert not any(call[:2] == ["forge", "verify-contract"] for call in log), log

        # 19. No temp file survives any of the runs above.
        assert not list(tmp_dir.iterdir()), list(tmp_dir.iterdir())

    return checks


def main() -> None:
    params_shared_copy()
    params_loader_cases()
    params_unset_coverage()
    network_profiles()
    dependencies_are_declared()
    network_params_keys()
    scripts_have_shebang_and_exec_bit()
    scripts_stay_within_bash_32()
    e2e_script_structure()
    deploy_script_has_no_hardcoded_address()
    deploy_script_structure()
    entrypoint_is_orchestration_only()
    verifier_skip_never_production()
    checks = behavioural_checks()
    print(f"Passed {checks} isolated deployment checks (no network calls or broadcasts).")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--fake":
        sys.exit(fake_tool(sys.argv[2], sys.argv[3:]))
    main()
