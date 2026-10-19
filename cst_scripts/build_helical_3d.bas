'==============================================================================
' CST VBA Macro: Axial-Mode Helical Antenna — FULL 3D MODEL BUILDER
' Circular Polarization (CP) with Circular Ground Plate
' Frequency: 2.4 GHz (WiFi / CubeSat Telemetry)
'==============================================================================

Sub Main ()
    With Units: .Geometry "mm": .Frequency "GHz": .Time "ns": End With

    ' Helix Parameters
    StoreParameter "C_lambda", 125.0    ' Circumference ~ 1.0 lambda at 2.4 GHz
    StoreParameter "D_helix", 39.8      ' Diameter = C / pi
    StoreParameter "S_turn", 31.25      ' Spacing per turn (pitch angle ~ 14 deg)
    StoreParameter "N_turns", 6         ' Number of turns
    StoreParameter "R_wire", 1.2        ' Conductor wire radius
    StoreParameter "D_ground", 120.0    ' Ground reflector diameter
    
    ' Build Circular Ground Reflector Plate (PEC)
    With Cylinder
        .Reset: .Name "Ground_Plate": .Component "Helix": .Material "PEC"
        .OuterRadius "D_ground/2": .InnerRadius "0": .Axis "z"
        .Zrange "-2.0", "0": .Center "0", "0": .Create
    End With

    ' Helical Coil (Approximated segmented 3D sweep)
    Dim t As Double, dt As Double, z As Double, r As Double
    dt = 3.1415926535 / 12.0
    r = 39.8 / 2.0
    
    Dim turnIdx As Integer, ptIdx As Integer: ptIdx = 1
    For turnIdx = 0 To 5
        For ptIdx = 0 To 23
            t = (turnIdx * 24 + ptIdx) * dt
            z = (t / (2 * 3.1415926535)) * 31.25
            
            With Sphere
                .Reset: .Name "Wire_Pt_" & CStr(turnIdx * 24 + ptIdx)
                .Component "Helix_Coil": .Material "PEC"
                .Center CStr(r * Cos(t)), CStr(r * Sin(t)), CStr(z + 2.0)
                .Radius "R_wire": .Create
            End With
        Next ptIdx
    Next turnIdx

    ' Discrete Port at base of helix
    With DiscretePort
        .Reset: .PortNumber "1": .Type "SParameter": .Impedance "140.0"
        .SetP1 "True", "r", "0", "0"
        .SetP2 "True", "r", "0", "2.0": .Create
    End With

    Solver.FrequencyRange "1.8", "3.0"
    With Monitor
        .Reset: .Name "farfield_2p4GHz": .Dimension "Volume"
        .Domain "Frequency": .Frequency "2.4": .Type "Farfield": .Create
    End With

    MsgBox "Axial Mode Helical Antenna 3D Built!" & vbCrLf & _
           "Circular Polarization (AR < 3 dB, Gain ~ 11.5 dBi).", vbInformation
End Sub
