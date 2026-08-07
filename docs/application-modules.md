# Application modules

**Audience:** application authors structuring their own codebase.
**Verified with:** `nimble test`

`ApplicationModule` is an application composition unit, not a dynamically loaded
plugin. Modules declare imports, providers, controllers, routes, startup/shutdown
hooks, and exports, then the root installs them with `installModules` before
startup. Installation validates the graph and keeps service/provider ownership
explicit.

Use modules for first-party application features that share a release and source
tree. Use a plugin when packaging an optional reusable integration with manifest
metadata. Neither is auto-discovered from files or imports; the composition root
chooses what is installed and in which dependency graph.

Exports describe intended inter-module service visibility, not a global locator.
Dispose request/task scopes at their owner boundary and do not let a module close
an adapter owned by the application or another module.
