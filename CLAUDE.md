# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single-file PowerShell tool (`Run.ps1`) that turns plain IoC lists into Suricata rules and detection lists. Everything about *what* gets detected and *how* it is rendered lives in `config.yaml` — `Run.ps1` is just the engine. Prefer changing `config.yaml` over changing `Run.ps1` when adjusting detection coverage.

## Commands

```powershell
.\Run.ps1                            # generate using .\config.yaml
.\Run.ps1 -ConfigPath path\to\x.yaml # generate using an alternate config
```

- Requires **Windows PowerShell 5.1** (the vendored `powershell-yaml` 0.4.7 under `packages\` ships net35/net45/netstandard2.1 assemblies).
- `Run.ps1` imports `powershell-yaml` from the user's module path if installed, otherwise directly from `packages\powershell-yaml\<version>\powershell-yaml.psd1`. It does not install anything.
- Relative `ioc_directory` / `rules_directory` resolve against the **script's own directory**, not the current working directory — the script can be invoked from anywhere.
- There are no tests, linters, or build steps. Verify changes by running the script and inspecting `rules\`.

### Verifying a change

`rules\` and `iocs\` are gitignored, so regenerating is free. After touching `Run.ps1` or `config.yaml`:

```powershell
Remove-Item rules\*.rules, rules\*.txt -Force
.\Run.ps1
$p = 'rules\combined_rules-<DDMMMYY>.rules'
@(Select-String -Path $p -Pattern '\{\w+\}').Count            # unresolved placeholders: must be 0
@(Get-Content $p | ? { $_ -notmatch 'sid:\d+;' }).Count       # rules missing a sid: must be 0
([IO.File]::ReadAllBytes($p))[0..2] -join ' '                 # must NOT be '239 187 191' (UTF-8 BOM)
```

Running twice must produce a byte-identical file. The local (gitignored) test corpus yields 2544 rules — 475 ip / 974 dns / 983 tls / 112 http — plus a 982-entry md5 list; a fresh clone has no `iocs\` at all and the script will report that the IoC directory does not exist.

## Architecture

`Run.ps1` is one pass over `templates × ioc files`, structured as a pipeline:

1. **Match** — `Get-NamedMatch` joins a template's `regex` list with `|` (so the list is an OR of alternatives that must share capture-group names), then takes the *first* match per trimmed line and returns a hashtable of the non-empty **named** capture groups. IoC files are one-indicator-per-line; anchored patterns are the norm.
2. **Render** — `New-Rule` drops matches missing any `required` group (required is checked against *captured* groups, never against `defaults`), then substitutes `defaults` first and captured values second, so a default like `dip: "{ip}"` resolves against the match. Substitution is ordinal `String.Replace`, not `-replace`, because IoC values contain regex and `$`-substitution metacharacters.
3. **Metadata** — `Get-MetadataOption` merges `global.metadata` with the template's `metadata` block (template wins); `Add-Metadata` renders it as a Suricata `metadata:` keyword and injects it before the rule's closing `)`, or into an explicit `{metadata}` placeholder when the template has one.
4. **Number and write** — rules are accumulated per template with `{sid}` still intact, deduplicated, *then* assigned SIDs. Output is written once at the end via `[System.IO.File]::WriteAllLines` with a BOM-less UTF-8 encoding.

### Invariants worth preserving

These are the places where the obvious PowerShell idiom is wrong, and where earlier versions broke:

- **Deduplicate before assigning SIDs.** The same indicator in two IoC files renders to identical rule text; if SIDs are stamped first, the duplicates no longer compare equal and both survive.
- **Write output once, never `-Append`.** Appending plus the daily `FileSerial` filename means a second run the same day doubles every rule with fresh SIDs.
- **Never `Out-File` / `Set-Content` for rule output.** Both emit a UTF-8 BOM in PS 5.1, which Suricata parses as part of the first rule. Use `Write-OutputFile`.
- **`continue` inside a function is not scoped to that function** — it propagates to the caller's `foreach` and silently skips the rest of that iteration. Use `return` in helper functions.
- **Bind parameters by name, never positionally.** The bug that made the previous version emit no rules at all was a hashtable passed positionally into the first parameter of a helper; it failed silently and the stray `continue` swallowed the empty result.

## Config schema

`config.yaml` is the source of truth and `README.MD` documents it — adding a setting means touching the parser in `Run.ps1`, the example in `config.yaml`, and the README section together.

- `global`: `sid_start`, `revision`, `ioc_directory`, `rules_directory`, `split_rules`, `metadata.rule_reference`.
- `templates[]`: `name`, `regex[]`, `template`, plus optional `required[]`, `defaults{}`, `lists[]`, `metadata{}`, `sid_start`, `revision` (the last two override the global values for that template only).
- Output filenames carry a `ddMMMyy` serial: `combined_rules-24SEP26.rules`, or `<name>-24SEP26.rules` when `split_rules: true`; lists become `<list>-24SEP26.txt`.

## Gotchas

- **Regex quality is a config concern.** Unanchored patterns match fragments of other indicators — an unanchored domain pattern will pull `bin.sh` out of `http://1.2.3.4:37455/bin.sh` and emit it as a DNS rule. The `dns` template is anchored with a negative lookahead for bare IPv4 for exactly this reason.
- `iocs\suricata_signatures.rules` is an output-shaped file sitting in the *input* directory; it is currently empty, but if populated it will be scanned as IoC input and generate rules from rules.
- The shipped `tls` template matches any 32-hex string and treats it as a JA3 hash, which on this corpus means MD5 file hashes are rendered as `ja3_hash` rules. That is the config as written, not a bug in the engine.
- This directory is **not** its own git repository — the enclosing repo is rooted at `Desktop\` and is currently in a detached-HEAD state with a large unrelated deletion staged. Be careful with repo-wide git commands.
