"""Check shipped language resources and CLI output without changing displays."""
import os
from pathlib import Path
import re
import subprocess

root = Path(__file__).resolve().parents[1]
resources = root / "build/macDisplayCtl.app/Contents/Resources"
if not resources.is_dir():
    resources = root / "App/Resources"
catalogs = {}
for language in ("en", "zh-Hans"):
    path = resources / f"{language}.lproj/Localizable.strings"
    catalogs[language] = dict(re.findall(r'^"((?:\\.|[^"\\])*)" = "((?:\\.|[^"\\])*)";', path.read_text(), re.M))
assert catalogs["en"].keys() == catalogs["zh-Hans"].keys(), "Translation keys differ"
used = set(re.findall(r'L10n\.(?:text|format)\("([^"]+)"', (root / "App/ScreenSwitch.swift").read_text()))
assert used <= catalogs["en"].keys(), f"Missing translations: {used - catalogs['en'].keys()}"
for key, english in catalogs["en"].items():
    assert re.findall(r"%[@dufs]", english) == re.findall(r"%[@dufs]", catalogs["zh-Hans"][key]), key
assert catalogs["en"]["macDisplayCtl"] == "macDisplayCtl"
assert catalogs["zh-Hans"]["macDisplayCtl"] == "屏幕切换"

for language in ("en", "zh-Hans", "fr"):
    environment = dict(os.environ, MACDISPLAYCTL_LANGUAGE=language)
    expected = "zh-Hans" if language.startswith("zh") else "en"
    def run(*args):
        return subprocess.run([str(root / "displayctl"), *args], env=environment,
                              capture_output=True, text=True, check=False)
    result = run("language")
    assert result.returncode == 0 and result.stdout.strip() == expected
    result = run("--help")
    assert result.returncode == 0
    assert ("用法：" if expected == "zh-Hans" else "Usage:") in result.stdout
    if expected == "en":
        assert not re.search(r"[\u3400-\u9fff]", result.stdout)
    result = run("list", "--invalid")
    assert result.returncode == 2
    assert ("无法识别的参数" if expected == "zh-Hans" else "Unrecognized argument") in result.stderr
    result = run("guard", "invalid")
    assert result.returncode == 2
    assert ("用法：" if expected == "zh-Hans" else "Usage:") in result.stderr
print("Packaged translations, CLI help/errors, guard messages, and language fallback passed.")
