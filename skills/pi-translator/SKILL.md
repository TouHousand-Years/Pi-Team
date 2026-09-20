---
name: pi-translator
description: Translate long documents or translation stages from other workflows with complete coverage, stable terminology, and structure preservation. Use for book chapters, papers, specifications, reports, or any translation too large or consequential for a single-pass response; supersedes agentling-paper-translator.
metadata:
  requires:
    mcps: ["pi-subagent"]
---

# Pi Translator

Use the `pi-team` contract to translate through explicit files and checkable stages. This skill owns segmentation and translation quality; `pi-team` owns delegation mechanics. The host owns source acquisition, external lookups, and final acceptance; Pi owns translation output files.

Before delegating, read [subagent-prompt.md](subagent-prompt.md). `pi-team` sends it verbatim together with the main session's complete current request.

## Translation contract

Before delegating, identify the source, target language, requested register, output format, and whether the user wants translation only or bilingual text. Preserve headings, lists, tables, citations, links, footnotes, code, formulas, numbers, and document order unless the user asks for adaptation.

Treat translation as lossless by default:

- Translate every semantic unit; never silently summarize or omit repetition.
- Keep names and technical terms consistent. Maintain `_glossary.md` when the document is long enough for terminology to drift.
- Leave code, identifiers, equations, citation keys, and URLs unchanged unless their surrounding prose needs translation.
- Mark unresolved wording as `[译疑: ...]` with a short reason instead of guessing.
- Apply user-provided terminology and style decisions before general conventions.

## Workflow

1. Put the complete source or a stable source manifest in the task directory. If terminology requires external research, the host gathers it and writes `_refs.md`; Pi works offline.
2. For a short, bounded translation, delegate one explicit output file. For a long document, write `_plan-draft.md` and split at semantic boundaries into ordered stages. Give every stage its exact input files, output file, and glossary dependency.
3. Run at most four independent stages concurrently. Keep adjacent sections sequential when they share terminology, cross-references, or narrative context.
4. After section stages pass, delegate a reconciliation stage that assembles the final document, resolves terminology drift and boundary duplication, and preserves the original hierarchy.
5. Review translation outputs read-only. Send every correction back to Pi with the exact file, passage, issue, and expected rendering.

## Acceptance

Finish only when all source units are accounted for, section order and non-prose elements are preserved, glossary terms are consistent, uncertainty markers are intentional, and boundary spot-checks show neither gaps nor duplicated text. Report the final file plus any unresolved translation decisions.
