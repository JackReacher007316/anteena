'==============================================================================
' CST VBA Macro: Resonant Half-Wave Dipole Antenna — FULL 3D MODEL BUILDER
' Standard Wire Dipole with Balanced Center Feed Gap
' Resonant Frequency: 2.45 GHz (Length ~ 0.47 lambda)
'==============================================================================

Sub Main ()
    With Units: .Geometry "mm": .Frequency "GHz": .Time "ns": End With

    StoreParameter "L_dipole", 58.0     ' Total dipole length
    StoreParameter "R_wire", 0.8        ' Conductor wire radius
    StoreParameter "G_feed", 2.0        ' Center feed gap

    ' Arm 1 (Positive Z)
    With Cylinder
        .Reset: .Name "Dipole_Arm1": .Component "Dipole": .Material "PEC"
        .OuterRadius "R_wire": .InnerRadius "0": .Axis "z"
        .Zrange "G_feed/2", "L_dipole/2": .Center "0", "0": .Create
    End With

    ' Arm 2 (Negative Z)
    With Cylinder
        .Reset: .Name "Dipole_Arm2": .Component "Dipole": .Material "PEC"
        .OuterRadius "R_wire": .InnerRadius "0": .Axis "z"
        .Zrange "-L_dipole/2", "-G_feed/2": .Center "0", "0": .Create
    End With

    ' Discrete Port (73 Ohm balanced feed)
    With DiscretePort
        .Reset: .PortNumber "1": .Type "SParameter": .Impedance "73.0"
        .SetP1 "True", "0", "0", "-G_feed/2"
        .SetP2 "True", "0", "0", "G_feed/2": .Create
    End With

    Solver.FrequencyRange "1.5", "3.5"
    With Monitor
        .Reset: .Name "farfield_2p45GHz": .Dimension "Volume"
        .Domain "Frequency": .Frequency "2.45": .Type "Farfield": .Create
    End With

    MsgBox "Half-Wave Dipole 3D Model Built!" & vbCrLf & _
           "Omnidirectional toroidal pattern (Directivity ~ 2.15 dBi).", vbInformation
End Sub
