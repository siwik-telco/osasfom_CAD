# osasfom_cad

`osasfom_cad` is a macOS CAD prototype for manual antenna geometry modeling.

The project uses a lightweight custom CAD model written in Swift, a SwiftUI desktop interface, and a SceneKit 3D viewport. The workflow is user-driven: instead of generating predefined antenna templates, the user builds geometry manually from editable solids.

## Current features

- manual creation of 3D primitives:
  - box
  - cylinder
  - sheet
- object list and active selection
- SceneKit 3D viewport with camera controls
- object picking directly in the scene
- editable body inspector:
  - name
  - dimensions
  - position
  - rotation
  - scale
  - visibility
  - material assignment
- built-in material library:
  - Copper
  - Aluminum
  - FR4
  - Vacuum
- JSON export of the current project

## Tech stack

- Swift 5.9
- Swift Package Manager
- SwiftUI
- SceneKit
- macOS 13+

## Project structure

```text
osasfom_cad
├── Package.swift
└── Sources
    ├── osasfom_cadCore
    │   ├── CADTypes.swift
    │   ├── CADDocument.swift
    │   └── SceneBuilder.swift
    └── osasfom_cad
        ├── osasfom_cad.swift
        └── MainView.swift
```

## Running from terminal

```bash
swift run osasfom_cad
```

## Running from Xcode

1. Open the repository folder or `Package.swift` in Xcode.
2. Wait until Xcode finishes loading the Swift package.
3. Select the scheme `osasfom_cad`.
4. Select destination `My Mac`.
5. Press `Run`.

## What the app does today

The app opens a desktop GUI with:
- a left sidebar for model objects
- a central 3D workspace
- a right-side inspector for the selected solid
- toolbar actions for creating, duplicating, deleting, and exporting bodies

## Planned next steps

- sketch-based modeling
- extrude operation
- boolean operations:
  - union
  - cut
- face and edge selection
- snapping
- mesh preview
- solver export
- project open/save workflow

## Notes

This is an early CAD foundation focused on fast iteration of geometry editing on macOS.
It is not yet a full production CAD kernel.
