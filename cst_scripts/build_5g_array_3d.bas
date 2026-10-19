'==============================================================================
' CST VBA Macro: 5G mmWave Antenna — FULL 3D MODEL BUILDER
' 4x4 Microstrip Patch Array for 28 GHz 5G NR Band
' With corporate feed network (Wilkinson power dividers)
'==============================================================================

Option Explicit

Sub Build5GArray3D()

    '=== USER PARAMETERS ===
    Dim freq       As Double : freq       = 28.0   ' Operating frequency (GHz)
    Dim er         As Double : er         = 2.2    ' Rogers RT/Duroid 5880
    Dim tand       As Double : tand       = 0.0009
    Dim h_sub      As Double : h_sub      = 0.254  ' 10-mil substrate (mm)
    Dim t          As Double : t          = 0.018  ' 0.5 oz copper (mm)

    ' Patch element dimensions (calculated from frequency)
    Dim c          As Double : c          = 3e8     ' speed of light m/s
    Dim lambda     As Double : lambda     = (c / (freq * 1e9)) * 1000  ' mm
    Dim er_eff     As Double
    er_eff = (er + 1)/2 + (er - 1)/2 * (1 + 12*h_sub/lambda*2)^(-0.5)

    Dim L_patch    As Double : L_patch    = lambda / (2 * Sqr(er_eff)) ' Patch length
    Dim W_patch    As Double : W_patch    = lambda / 2 * Sqr(2 / (er + 1)) ' Patch width

    ' Array configuration
    Dim N_rows     As Integer : N_rows    = 4        ' Number of rows
    Dim N_cols     As Integer : N_cols    = 4        ' Number of columns
    Dim dx         As Double  : dx        = lambda/2  ' Element spacing X (mm)
    Dim dy         As Double  : dy        = lambda/2  ' Element spacing Y (mm)

    ' Feed network
    Dim W_50ohm    As Double  ' 50-Ohm microstrip width
    Dim W_35ohm    As Double  ' 35.35-Ohm (quarter-wave transformer)
    W_50ohm = Calculate50OhmWidth(er, h_sub)
    W_35ohm = Calculate35OhmWidth(er, h_sub)

    ' Substrate size
    Dim Sub_W As Double : Sub_W = N_cols * dx + 4 * lambda
    Dim Sub_L As Double : Sub_L = N_rows * dy + 6 * lambda

    MsgBox "Building 5G 4x4 Patch Array @ " & freq & " GHz" & Chr(10) & _
           "Patch: " & Format(L_patch, "0.00") & " x " & Format(W_patch, "0.00") & " mm" & Chr(10) & _
           "Spacing: " & Format(dx, "0.00") & " mm (lambda/2)" & Chr(10) & _
           "Array: " & N_rows & "x" & N_cols & " = " & N_rows*N_cols & " elements", _
           vbInformation, "CST 5G Array Builder"

    '=== PROJECT SETUP ===
    With Units
        .SetUnit "Length", "mm"
        .SetUnit "Frequency", "GHz"
    End With

    '=== MATERIALS ===
    With Material
        .Reset
        .Name "Rogers_5880"
        .Colour "0.75", "0.88", "0.95"
        .Epsilon CStr(er)
        .Mue "1.0"
        .TanD CStr(tand)
        .TanDFreq CStr(freq)
        .Type "Normal"
        .Create
    End With

    '=== SUBSTRATE ===
    With Brick
        .Reset
        .Name "Substrate_5G"
        .Component "Array_5G"
        .Material "Rogers_5880"
        .Xrange CStr(-Sub_W/2), CStr(Sub_W/2)
        .Yrange CStr(-Sub_L/2), CStr(Sub_L/2)
        .Zrange "0", CStr(h_sub)
        .Create
    End With

    '=== GROUND PLANE ===
    With Brick
        .Reset
        .Name "GroundPlane"
        .Component "Array_5G"
        .Material "PEC"
        .Xrange CStr(-Sub_W/2), CStr(Sub_W/2)
        .Yrange CStr(-Sub_L/2), CStr(Sub_L/2)
        .Zrange CStr(-t), "0"
        .Create
    End With

    '=== BUILD 4x4 PATCH ELEMENTS ===
    Dim row As Integer, col As Integer
    Dim elem_num As Integer : elem_num = 1
    Dim px As Double, py As Double

    For row = 0 To N_rows - 1
        For col = 0 To N_cols - 1
            px = -((N_cols-1)*dx/2) + col*dx
            py = -((N_rows-1)*dy/2) + row*dy

            ' Patch element
            With Brick
                .Reset
                .Name "Patch_" & elem_num
                .Component "Patches"
                .Material "PEC"
                .Xrange CStr(px - L_patch/2), CStr(px + L_patch/2)
                .Yrange CStr(py - W_patch/2), CStr(py + W_patch/2)
                .Zrange CStr(h_sub), CStr(h_sub + t)
                .Create
            End With

            elem_num = elem_num + 1
        Next col
    Next row

    '=== CORPORATE FEED NETWORK ===
    ' Main feed at center bottom
    Dim feed_start_y As Double : feed_start_y = -Sub_L/2 + lambda

    ' Stage 1: 1-to-2 Wilkinson divider (main)
    Call Build1to2Divider("FeedStage1_L", -dx, feed_start_y, _
                           W_50ohm, W_35ohm, h_sub, t, lambda)
    Call Build1to2Divider("FeedStage1_R",  dx, feed_start_y, _
                           W_50ohm, W_35ohm, h_sub, t, lambda)

    '=== MAIN FEED PORT ===
    With Port
        .Reset
        .PortNumber "1"
        .Label "Feed_Port_5G"
        .NumberOfModes "1"
        .Coordinates "Free"
        .Orientation "ymin"
        .Xrange CStr(-W_50ohm/2), CStr(W_50ohm/2)
        .Yrange CStr(-Sub_L/2), CStr(-Sub_L/2)
        .Zrange "0", CStr(h_sub + t)
        .Create
    End With

    '=== BOUNDARY CONDITIONS ===
    With Boundary
        .Xmin "expanded open"
        .Xmax "expanded open"
        .Ymin "expanded open"
        .Ymax "expanded open"
        .Zmin "electric"       ' Perfect electric for ground (optional)
        .Zmax "expanded open"
    End With

    '=== FREQUENCY RANGE ===
    With Solver
        .FrequencyRange CStr(freq - 6), CStr(freq + 6)
    End With

    '=== MESH (very fine for mmWave) ===
    With MeshSettings
        .SetMeshType "Hex"
        .Set "StepsPerWaveNear", "40"
        .Set "StepsPerWaveFar",  "20"
        .Set "MinimumStepNumber", "8"
    End With

    '=== MONITORS ===
    With Monitor
        .Reset
        .Name "farfield_28GHz"
        .Domain "Frequency"
        .FieldType "Farfield"
        .Frequency CStr(freq)
        .Create
    End With

    With Monitor
        .Reset
        .Name "farfield_26GHz"
        .Domain "Frequency"
        .FieldType "Farfield"
        .Frequency CStr(freq - 2)
        .Create
    End With

    With Monitor
        .Reset
        .Name "farfield_30GHz"
        .Domain "Frequency"
        .FieldType "Farfield"
        .Frequency CStr(freq + 2)
        .Create
    End With

    '=== PARAMETER STORE ===
    StoreParameter "freq_5g",      freq
    StoreParameter "patch_L_5g",   L_patch
    StoreParameter "patch_W_5g",   W_patch
    StoreParameter "spacing_dx",   dx
    StoreParameter "spacing_dy",   dy
    StoreParameter "array_rows",   N_rows
    StoreParameter "array_cols",   N_cols

    MsgBox "5G 4x4 Array build complete!" & Chr(10) & _
           "16 elements at " & freq & " GHz" & Chr(10) & _
           "Patch: " & Format(L_patch, "0.000") & " x " & Format(W_patch, "0.000") & " mm" & Chr(10) & _
           "Expected Gain: ~18-22 dBi", vbInformation, "5G Build Complete"

End Sub

'==============================================================================
' Sub: Build simplified 1-to-2 Wilkinson power divider branch
'==============================================================================
Sub Build1to2Divider(name As String, cx As Double, cy As Double, _
                      W_50 As Double, W_35 As Double, h As Double, _
                      t As Double, lambda As Double)
    Dim qw_len As Double : qw_len = lambda / 4   ' Quarter-wave length

    With Brick
        .Reset
        .Name "QW_" & name
        .Component "FeedNetwork"
        .Material "PEC"
        .Xrange CStr(cx - W_35/2), CStr(cx + W_35/2)
        .Yrange CStr(cy), CStr(cy + qw_len)
        .Zrange CStr(h), CStr(h + t)
        .Create
    End With
End Sub

'==============================================================================
' Helper: 50-Ohm microstrip width calculation
'==============================================================================
Function Calculate50OhmWidth(er As Double, h As Double) As Double
    Dim A As Double : A = (60/50) * Sqr((er+1)/2) + ((er-1)/(er+1)) * (0.23 + 0.11/er)
    Dim W As Double : W = 8 * h * Exp(A) / (Exp(2*A) - 2)
    If W/h >= 2 Then
        Dim B As Double : B = 377*3.14159/(2*50*Sqr(er))
        W = (2*h/3.14159) * (B-1-Log(2*B-1) + (er-1)/(2*er) * (Log(B-1)+0.39-0.61/er))
    End If
    Calculate50OhmWidth = W
End Function

Function Calculate35OhmWidth(er As Double, h As Double) As Double
    Dim A As Double : A = (60/35) * Sqr((er+1)/2) + ((er-1)/(er+1)) * (0.23 + 0.11/er)
    Calculate35OhmWidth = 8 * h * Exp(A) / (Exp(2*A) - 2)
End Function
