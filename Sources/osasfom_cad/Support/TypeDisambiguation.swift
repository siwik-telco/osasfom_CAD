import osasfom_cadCore

/// SwiftUI declares its own `Axis` (horizontal/vertical). A module-scope alias
/// resolves unqualified uses in this target to the geometric axis, so the views
/// do not have to spell out `osasfom_cadCore.Axis` everywhere.
typealias Axis = osasfom_cadCore.Axis
