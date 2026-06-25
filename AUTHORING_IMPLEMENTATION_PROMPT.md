# Authoring Implementation Prompt

Use this prompt to start the next implementation pass.

## Prompt

We are in the `UCI_Navigator` repo. Ignore everything in the `old/` folder.

Implement the authoring API described in `AUTHORING_SPEC.md`, using `authoringExample.lua` as the target authoring example.

Current Navigator is not in production. Do not treat existing public API shapes as compatibility requirements. It is acceptable to remove or reshape legacy/native authoring forms if that makes the implementation clearer. Prefer making Navigator's internal representation as close to the new authoring model as reasonable, instead of building a large compatibility compiler that translates into an awkward older shape.

The intended public API is:

```lua
local config = Navigator.compile({
  -- authored project
})

Navigator.apply(config)
```

`Navigator.compile(...)` should transform authoring format into Navigator's runtime configuration. `Navigator.apply(...)` should install that configuration into the active runtime. Do not keep or add `Navigator.configure(...)` / `Navigator.project(...)` as aliases unless a short local migration step truly reduces implementation risk.

Core implementation goals:

- Add `Navigator.compile(...)`.
- Add `Navigator.apply(...)`.
- Move runtime configuration toward the authoring model where reasonable.
- Support constructors: `group(spec)`, `group(spec, pages)`, `page(spec)`, and `region(spec)`.
- Support typed symbolic references during compile: `pages.*`, `groups.*`, and `regions.*`.
- Support `groups.root` as the built-in root group reference.
- Support bare group mode sentinels: `mode = interlocked` and `mode = independent`.
- Compile or normalize page `content` into the runtime representation.
- Compile page `controls` string values through `Controls[controlName]`.
- Compile global `accessControls` and `historyControls` string values through `Controls[controlName]`.
- Add first-class authored `regions` with owner-scoped lifetime and default `content`.
- Support region fills in page content, such as `regions.footer("Audio Settings Footer")`.
- Return compiled handles on the config for custom script use:

```lua
Navigator.open(config.pages.audio)
Navigator.close(config.pages.audio)
```

Region behavior:

- A region exists while its owner is active.
- A region shows its default content when no more specific active page fills it.
- Active page fills should prefer the most specific active page.
- Same-depth conflicting fills for the same region should error instead of guessing.
- Prefer implementing regions as a real runtime concept. It is acceptable to compile regions into the current `frameRoles` / `frameOverrides` machinery only as a temporary stepping stone if that is clearly lower risk.

Validation should be strict and clear:

- unknown `pages.*`, `groups.*`, or `regions.*` references.
- duplicate page, group, or region IDs.
- invalid group mode.
- invalid `owner`.
- `startAt` that does not reference a valid page for that group.
- region fills that reference unknown regions.
- unsupported page control names.
- missing Q-SYS controls when detectable.
- same-depth active region fill conflicts.

Keep changes pragmatic and scoped. Prefer adapting existing normalization/validation/runtime helpers in `Navigator.lua` over creating a parallel implementation. Existing examples and docs may be updated to the new API; they do not need to preserve old public shapes.

Suggested first pass:

1. Read `AUTHORING_SPEC.md`, `authoringExample.lua`, `Navigator.lua`, and the active examples in `Examples/`.
2. Identify the current native config shape and where `configure` performs normalization/validation.
3. Decide whether `apply` should reuse/replace the current configure implementation.
4. Implement compile-time marker objects for `group`, `page`, `region`, typed refs, mode sentinels, and region fill values.
5. Implement `Navigator.compile(...)` to emit native config plus `config.pages`, `config.groups`, and `config.regions` handles.
6. Implement `Navigator.apply(...)`.
7. Validate `authoringExample.lua` with a mocked Q-SYS environment.
8. Update and validate the active examples against the new API.

Do not update public README/docs broadly until the implementation shape is proven. Keep `AUTHORING_SPEC.md` and `authoringExample.lua` as the implementation source of truth during the first pass.
