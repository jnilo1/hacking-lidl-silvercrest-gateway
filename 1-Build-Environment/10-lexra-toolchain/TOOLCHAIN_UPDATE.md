# TOOLCHAIN_UPDATE.md

## Project scope

This repository contains the build environment, toolchain, kernel, rootfs, and user-data components for RTL8196E gateways based on Realtek RTL8196E / Lexra LX4380.

Your task is **not** to port Alpine Linux as a full distribution.

Your task is to **modernize the existing x-tools / crosstool-NG toolchain** by reusing **Alpine Linux sources, versions, and downstream patches** for:
- `binutils`
- `gcc`
- `musl`

while preserving:
- the current `x-tools` workflow
- the current `crosstool-NG` orchestration
- the current Lexra / RTL-specific support required by the gateway

---

## Main objective

Update the existing `mips-lexra-linux-musl` toolchain so that:

- `binutils` is rebased on Alpine's package version and patch set
- `gcc` is rebased on Alpine's package version and patch set
- `musl` is rebased on Alpine's package version and patch set
- Lexra-specific patches are preserved or adapted as needed
- the resulting toolchain still builds into `x-tools`
- the resulting toolchain is restricted to the smallest practical set of tools required for gateway development

---

## Non-goals

Do **not**:
- replace `crosstool-NG` with Alpine `abuild`
- turn this repository into a full Alpine port
- introduce `apk` / package-manager workflows as part of the toolchain migration
- modify unrelated project areas unless strictly needed for the toolchain migration
- broaden the toolchain to support generic desktop or multi-language development

---

## Guiding principles

1. **Keep x-tools**
   - `x-tools` remains the final toolchain layout.
   - `crosstool-NG` remains the build orchestrator.

2. **Use Alpine as the base for generic components**
   - Alpine is the source of truth for versions and downstream fixes for:
     - `binutils`
     - `gcc`
     - `musl`

3. **Keep project-specific delta minimal**
   - Only retain patches that are truly required for:
     - Lexra
     - RTL8196E
     - the gateway’s constrained embedded target

4. **Do not stack patches blindly**
   - If a component is rebased on Alpine patches, do not automatically keep bundled crosstool-NG patches on top.
   - Re-evaluate bundled ct-ng patches one by one.

5. **Minimize the toolchain**
   - Build only the parts required for gateway development.
   - Avoid unnecessary languages, runtimes, libraries, or tooling.

6. **Preserve reproducibility**
   - The final build must remain deterministic and documented.
   - Prefer repository-local configuration and patch paths over user-global state when possible.

---

## Repository areas to inspect first

Start with the current toolchain implementation under the build environment chapter, especially:
- the chapter `10-lexra-toolchain`
- the current `crosstool-NG` config
- the current patch layout
- the current build scripts
- the current handling of local ct-ng patches
- current target tuple / architecture / ABI / float settings

You must understand the current workflow before changing it.

---

## Required migration model

Treat each toolchain component as layered in this order:

1. **Upstream base**
2. **Alpine downstream base**
3. **Optional ct-ng bundled patches still proven necessary**
4. **Lexra / RTL project-specific patches**

The goal is to move from the current model:

- upstream
- ct-ng bundled patches
- local Lexra patches

toward this cleaner model:

- upstream + Alpine patches = generic base
- Lexra / RTL patches = local delta
- ct-ng bundled patches = only if still necessary after review

---

## Required implementation order

Follow this order unless you have a very strong technical reason not to.

### Step 1 — Audit and freeze current state

Before making changes:

- identify the current versions of:
  - `binutils`
  - `gcc`
  - `musl`
- identify the current target tuple and architecture settings
- identify all currently applied:
  - ct-ng bundled patches
  - local Lexra patches
  - project-specific source edits
- document the current `x-tools` contents and what is actually used by the gateway workflow

Deliverable for this step:
- a concise baseline summary

---

### Step 2 — Rebase `binutils`

Rebase `binutils` first.

Actions:
- identify the Alpine version and Alpine patch set
- import or reproduce Alpine’s relevant downstream changes
- re-apply or adapt Lexra patches
- disable or drop bundled ct-ng patches that are no longer needed
- verify basic assembler/linker functionality

Validation:
- assembler works
- linker works
- `objdump`, `readelf`, `nm`, `strip` work
- simple target objects link correctly

Why first:
- `binutils` is usually easier to isolate than GCC
- this reduces uncertainty before tackling compiler codegen

---

### Step 3 — Rebase `gcc`

Then rebase `gcc`.

Actions:
- identify the Alpine version and patch set
- import Alpine-specific downstream patches/config choices
- re-apply or adapt Lexra patches
- review whether old ct-ng bundled GCC patches remain necessary
- keep the language set minimal

Validation:
- compiler builds successfully
- target hello-world C code compiles
- generated objects link with the updated binutils
- no unnecessary frontends are enabled

Important:
- only keep what is needed for gateway development
- avoid extra language frontends and support libraries unless strictly required

---

### Step 4 — Rebase `musl`

Then rebase `musl`.

Actions:
- identify the Alpine version and patch set
- import Alpine musl patches
- re-apply or adapt Lexra-specific musl patches
- keep the existing target ABI and CPU constraints coherent

Validation:
- musl builds successfully
- sysroot is populated correctly
- dynamic/static linking behavior remains consistent with project needs

Important:
- if the current musl patch set already works well, preserve stability where possible
- reduce local delta only where safe

---

### Step 5 — Validate real gateway userland builds

Once `binutils`, `gcc`, and `musl` are updated, validate with real project artifacts.

Minimum validation targets:
- hello world
- musl rebuild
- BusyBox
- ideally one or two additional project binaries relevant to the gateway

The point is not just "toolchain builds".
The point is "toolchain is actually usable for the gateway".

---

### Step 6 — Minimize the x-tools output

After the migration works, reduce the final `x-tools` payload.

Keep only what is actually needed for:
- kernel development
- BusyBox build
- musl build
- Dropbear build
- gateway utilities
- ELF inspection/debugging as needed

Prefer to keep:
- core compiler tools
- linker/assembler/binutils essentials
- only the language/runtime support strictly required for C development

Avoid unnecessary components such as:
- extra language frontends
- unused runtime libraries
- features meant for generic workstation development
- optional extras not needed by this project

Document exactly what was kept and why.

---

## Toolchain minimization policy

Assume the gateway only needs a narrow embedded Linux development toolchain.

Bias toward:
- C only
- target-specific binaries only
- no extra languages unless explicitly required
- no broad feature enablement "just in case"

The default approach is:
- **remove if not clearly needed**
- **keep only if justified by actual repository usage**

---

## Patch handling policy

For every patch, classify it as one of:

- `upstream already includes this`
- `Alpine downstream patch`
- `crosstool-NG bundled patch still needed`
- `Lexra / RTL-specific local patch`
- `obsolete patch that should be removed`

For patches that fail to apply, document:
- what changed
- whether the patch became unnecessary
- whether Alpine already covers it
- whether it must be rewritten for the newer base

Never keep patches whose purpose you cannot explain.

---

## Required outputs

Your work must produce:

1. updated crosstool-NG configuration
2. updated patch organization
3. a clear mapping of:
   - Alpine-derived changes
   - Lexra-specific changes
   - dropped ct-ng bundled changes
4. a minimal `x-tools` result aligned with project needs
5. a concise migration report

---

## Required report format

At the end, provide a structured report with:

### 1. Initial baseline
- current versions
- current patch model
- current target settings

### 2. Changes made
- `binutils`
- `gcc`
- `musl`
- config and patch path changes
- x-tools minimization changes

### 3. Patch decisions
- kept
- adapted
- dropped
- reason for each category

### 4. Validation
- what builds passed
- what remains uncertain
- what still requires manual review or target runtime testing

### 5. Final toolchain scope
- what remains in x-tools
- what was removed
- why this reduced set is sufficient for gateway development

---

## Success criteria

The migration is successful only if all of the following are true:

- the toolchain still builds through `crosstool-NG`
- the result still lands in `x-tools`
- Alpine-derived versions/patches are used for `binutils`, `gcc`, and `musl`
- Lexra support is preserved
- the final toolchain is smaller and more focused than before
- BusyBox and at least minimal real project userland build correctly
- the patch stack is cleaner and easier to understand than before

---

## Decision rule when in doubt

When a choice is ambiguous, prefer:

1. Alpine as the generic base
2. Lexra/RTL as the only local specificity
3. minimal x-tools contents
4. explicit, maintainable configuration over convenience hacks
5. repository-local reproducibility over user-global state
