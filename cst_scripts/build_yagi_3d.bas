'==============================================================================
' CST VBA Macro: Yagi-Uda Array Antenna — FULL 3D MODEL BUILDER
' High-Gain Endfire Directional Array (1 Reflector, 1 Driven Dipole, 3 Directors)
' Design Frequency: 2.4 GHz
'==============================================================================

Sub Main ()
    With Units: .Geometry "mm": .Frequency "GHz": .Time "ns": End With

    StoreParameter "L_ref", 64.0        ' Reflector element length (~0.50 lambda)
    StoreParameter "L_drv", 58.0        ' Driven dipole element length (~0.47 lambda)
    StoreParameter "L_dir1", 52.0       ' Director 1 length (~0.42 lambda)
    StoreParameter "L_dir2", 50.0       ' Director 2 length
    StoreParameter "L_dir3", 48.0       ' Director 3 length
    StoreParameter "S_ref", 25.0        ' Spacing: Reflector to Driven (~0.20 lambda)
    StoreParameter "S_dir", 22.0        ' Spacing: Driven to Directors (~0.18 lambda)
    StoreParameter "R_rod", 1.0         ' Rod radius
    
    ' Reflector Element (at X = -S_ref)
    With Cylinder
        .Reset: .Name "Reflector": .Component "Yagi": .Material "PEC"
        .OuterRadius "R_rod": .InnerRadius "0": .Axis "y"
        .Yrange "-L_ref/2", "L_ref/2": .Center "-S_ref", "0": .Create
    End With

    ' Driven Element (at X = 0) with feed gap
    With Cylinder
        .Reset: .Name "Driven_Arm1": .Component "Yagi": .Material "PEC"
        .OuterRadius "R_rod": .InnerRadius "0": .Axis "y"
        .Yrange "1.0", "L_drv/2": .Center "0", "0": .Create
    End With
    With Cylinder
        .Reset: .Name "Driven_Arm2": .Component "Yagi": .Material "PEC"
        .OuterRadius "R_rod": .InnerRadius "0": .Axis "y"
        .Yrange "-L_drv/2", "-1.0": .Center "0", "0": .Create
    End With

    ' Director 1 (at X = S_dir)
    With Cylinder
        .Reset: .Name "Director_1": .Component "Yagi": .Material "PEC"
        .OuterRadius "R_rod": .InnerRadius "0": .Axis "y"
        .Yrange "-L_dir1/2", "L_dir1/2": .Center "S_dir", "0": .Create
    End With

    ' Director 2 (at X = 2 * S_dir)
    With Cylinder
        .Reset: .Name "Director_2": .Component "Yagi": .Material "PEC"
        .OuterRadius "R_rod": .InnerRadius "0": .Axis "y"
        .Yrange "-L_dir2/2", "L_dir2/2": .Center "2 * S_dir", "0": .Create
    End With

    ' Director 3 (at X = 3 * S_dir)
    With Cylinder
        .Reset: .Name "Director_3": .Component "Yagi": .Material "PEC"
        .OuterRadius "R_rod": .InnerRadius "0": .Axis "y"
        .Yrange "-L_dir3/2", "L_dir3/2": .Center "3 * S_dir", "0": .Create
    End With

    ' Discrete Port at Driven Element gap
    With DiscretePort
        .Reset: .PortNumber "1": .Type "SParameter": .Impedance "50.0"
        .SetP1 "True", "0", "-1.0", "0"
        .SetP2 "True", "0", "1.0", "0": .Create
    End With

    Solver.FrequencyRange "2.0", "2.8"
    With Monitor
        .Reset: .Name "farfield_2p4GHz": .Dimension "Volume"
        .Domain "Frequency": .Frequency "2.4": .Type "Farfield": .Create
    End With

    MsgBox "5-Element Yagi-Uda Antenna 3D Built!" & vbCrLf & _
           "Endfire Directivity ~ 9.5-11.0 dBi at 2.4 GHz.", vbInformation
End Sub
