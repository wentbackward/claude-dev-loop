---
component: {{COMPONENT_NAME}}
layer: {{LAYER_NUMBER_0_AT_THE_BOTTOM}}
kind: component        # or: composition-root (entry points, CLI, job runner, app wiring)
paths: {{PATH_GLOBS_SEPARATED_BY_SPACES}}
depends_on: {{COMPONENT_NAMES_IT_MAY_USE}}
max_lines: {{SIZE_BUDGET_IN_LINES}}
---
<!-- One card per component, in the architecture.cards folder (default docs/architecture/). The scripts read
only the header above. component: a plain name (letters, digits, _ . -). layer: a number, 0 at the
bottom; no dependency may go up a layer (solve an upward need with an interface the lower component
defines). kind: a composition root may depend on any layer below it and its fan-out is not flagged; keep
it thin, split it per layer when it grows. paths: shell globs on the repository path, * also matches /,
the longest matching glob wins. depends_on: optional; when the line is there (even empty), a dependency on
a component not listed is a violation. max_lines: optional, overrides architecture.budget. -->

## Responsibility

{{WHAT_THIS_COMPONENT_OWNS_IN_ONE_OR_TWO_SENTENCES}}

## Public interface

{{THE_MODULES_FUNCTIONS_OR_ENDPOINTS_OTHER_COMPONENTS_MAY_USE}}

## Notes

{{CONSTRAINTS_INVARIANTS_AND_LINKS_TO_DECISIONS}}
