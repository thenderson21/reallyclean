# ReallyClean

`reallyclean.sh` and `reallyclean.ps1` are aggressive cleanup utilities for .NET and .NET MAUI projects.

They are intended to return a project to a "fresh clone" state by removing build output, IDE caches, NuGet caches, temporary files, and disposable .NET state.

> **Important**
>
> These scripts do **not** uninstall .NET SDKs, runtimes, workloads, Visual Studio, Rider, VS Code, Android SDKs, Java, Xcode, or signing certificates. A true "factory fresh" machine requires uninstalling those components separately.

---

## Features

### Default

- Stops .NET build servers
- Runs `dotnet clean`
- Removes:
  - `bin`
  - `obj`
  - `TestResults`
  - `AppPackages`
  - `Publish`
  - `publish`
  - `artifacts`

---

### Rider

Everything in **Default**, plus:

- Removes Rider caches
- Removes Rider indexes
- Removes ReSharper host caches
- Removes project `.idea` state
- Performs **Deep** cleanup

---

### VSCode / VStudio

Everything in **Default**, plus:

- Removes Visual Studio caches
- Removes MEF caches
- Removes ComponentModel caches
- Removes VS Code caches
- Removes workspace storage
- Removes project `.vs` state
- Performs **Deep** cleanup

---

### Deep

Everything in **Default**, plus:

- Clears all NuGet caches
- Clears restored NuGet packages
- Clears disposable `.dotnet` state
- Runs `dotnet workload clean` (when supported)
- Removes Roslyn temporary files
- Removes MSBuild temporary files
- Removes NuGet scratch directories
- Removes MAUI/Xamarin caches
- Removes known .NET temporary files

The next build will automatically restore packages and regenerate caches.

---

# Linux / macOS

```bash
chmod +x reallyclean.sh

./reallyclean.sh
./reallyclean.sh rider
./reallyclean.sh vscode
./reallyclean.sh deep

# Preview only
./reallyclean.sh deep --dry-run

# Skip confirmation
./reallyclean.sh deep --yes
```

---

# Windows

```powershell
.
eallyclean.ps1

.
eallyclean.ps1 Rider
.
eallyclean.ps1 VSCode
.
eallyclean.ps1 Deep

# Preview only
.
eallyclean.ps1 Deep -WhatIf

# Skip confirmation
.
eallyclean.ps1 Deep -Force
```

---

## Safety

The scripts intentionally refuse to run from:

- `/`
- A drive root
- Your home directory

They also verify that the current directory appears to be a .NET repository before performing any destructive operations.

---

## Recommended Workflow

Before running:

1. Close Rider, Visual Studio, and VS Code.
2. Stop Android emulators.
3. Stop `dotnet watch`.
4. Commit any work in progress.

After cleaning:

```text
dotnet restore
dotnet workload list
dotnet build
```

The first build after a deep cleanup may take noticeably longer because packages and caches must be recreated.

---

## License

MIT
