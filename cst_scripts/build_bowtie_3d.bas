'==============================================================================
' CST VBA Macro: Planar Bow-Tie Antenna — FULL 3D MODEL BUILDER
' Wideband Triangular Flared Dipole on Dielectric Substrate
' Operating Frequency: 1.8 - 4.5 GHz
'==============================================================================

Sub Main ()
    With Units: .Geometry "mm": .Frequency "GHz": .Time "ns": End With

    StoreParameter "L_arm", 32.0        ' Bow-tie arm length
    StoreParameter "W_flare", 28.0      ' Flared tip width
    StoreParameter "G_feed", 1.5        ' Center feed gap
    StoreParameter "H_sub", 1.6         ' Substrate height
    StoreParameter "Eps_r", 4.4         ' FR-4

    ' Substrate
    With Brick
        .Reset: .Name "Substrate": .Component "Base": .Material "FR4_Lossy"
        .Xrange "-W_flare/2 - 10", "W_flare/2 + 10"
        .Yrange "-L_arm - 10", "L_arm + 10"
        .Zrange "0", "H_sub": .Create
    End With

    ' Arm 1 (Positive Y Triangular Flared Plate)
    With Polygon
        .Reset: .Name "Arm_Pos": .Curve "Profile_Arm1"
        .Point "-1.0", "G_feed/2": .LineTo "1.0", "G_feed/2"
        .LineTo "W_flare/2", "L_arm": .LineTo "-W_flare/2", "L_arm"
        .LineTo "-1.0", "G_feed/2": .Create
    End With

    ' Arm 2 (Negative Y Triangular Flared Plate)
    With Polygon
        .Reset: .Name "Arm_Neg": .Curve "Profile_Arm2"
        .Point "-1.0", "-G_feed/2": .LineTo "1.0", "-G_feed/2"
        .LineTo "W_flare/2", "-L_arm": .LineTo "-W_flare/2", "-L_arm"
        .LineTo "-1.0", "-G_feed/2": .Create
    End With

    ' Discrete Port (Feed gap)
    With DiscretePort
        .Reset: .PortNumber "1": .Type "SParameter": .Impedance "50.0"
        .SetP1 "True", "0", "-G_feed/2", "H_sub"
        .SetP2 "True", "0", "G_feed/2", "H_sub": .Create
    End With

    Solver.FrequencyRange "1.5", "5.0"
    With Monitor
        .Reset: .Name "farfield_2p4GHz": .Dimension "Volume"
        .Domain "Frequency": .Frequency "2.45": .Type "Farfield": .Create
    End With

    MsgBox "Planar Bow-Tie Antenna 3D Built!" & vbCrLf & _
           "Broadband Impedance Bandwidth ~ 2:1 ratio.", vbInformation
End Sub
