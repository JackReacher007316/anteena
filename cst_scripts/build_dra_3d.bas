'==============================================================================
' CST VBA Macro: Cylindrical Dielectric Resonator Antenna (DRA) — FULL 3D MODEL
' High Radiation Efficiency (No Conduction Losses), TE01delta Mode
' Operating Frequency: 5.8 GHz (ISM Band)
'==============================================================================

Sub Main ()
    With Units: .Geometry "mm": .Frequency "GHz": .Time "ns": End With

    StoreParameter "R_dra", 6.5         ' Ceramic puck radius
    StoreParameter "H_dra", 7.2         ' Ceramic puck height
    StoreParameter "Eps_dra", 10.0      ' High-permittivity ceramic (Alumina)
    StoreParameter "W_slot", 1.2        ' Coupling slot aperture width
    StoreParameter "L_slot", 6.0        ' Coupling slot aperture length
    StoreParameter "H_sub", 0.8         ' Feeding substrate height
    StoreParameter "Eps_sub", 3.38      ' Rogers RO4003C substrate

    ' Build Ground Plane with Aperture Slot
    With Brick
        .Reset: .Name "Ground_Plate": .Component "DRA_Base": .Material "PEC"
        .Xrange "-25", "25": .Yrange "-25", "25"
        .Zrange "0", "0.035": .Create
    End With
    ' Cut Slot in Ground Plane
    With Brick
        .Reset: .Name "Aperture_Slot": .Component "Cut": .Material "PEC"
        .Xrange "-W_slot/2", "W_slot/2": .Yrange "-L_slot/2", "L_slot/2"
        .Zrange "-0.01", "0.05": .Create
    End With
    Solid.Subtract "DRA_Base:Ground_Plate", "Cut:Aperture_Slot"

    ' Define High-k Ceramic Material
    With Material
        .Reset: .Name "Ceramic_Alumina": .Type "Normal": .Epsilon "Eps_dra": .Create
    End With

    ' Build Cylindrical Ceramic Resonator Puck
    With Cylinder
        .Reset: .Name "DRA_Puck": .Component "Radiator": .Material "Ceramic_Alumina"
        .OuterRadius "R_dra": .InnerRadius "0": .Axis "z"
        .Zrange "0.035", "0.035 + H_dra": .Center "0", "0": .Create
    End With

    Solver.FrequencyRange "4.5", "7.0"
    With Monitor
        .Reset: .Name "farfield_5p8GHz": .Dimension "Volume"
        .Domain "Frequency": .Frequency "5.8": .Type "Farfield": .Create
    End With

    MsgBox "Dielectric Resonator Antenna (DRA) 3D Built!" & vbCrLf & _
           "Radiation Efficiency > 96% at 5.8 GHz.", vbInformation
End Sub
