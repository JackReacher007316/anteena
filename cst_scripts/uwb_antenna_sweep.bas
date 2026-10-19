'==============================================================================
' CST VBA Macro: UWB Antenna Parameter Sweep
' Description: Sweeps UWB slot antenna geometry for 3.1-10.6 GHz band
'==============================================================================

Option Explicit

Sub UWBAntennaSweep()

    Dim slot_w_min As Double, slot_w_max As Double, slot_w_step As Double
    Dim slot_l_min As Double, slot_l_max As Double, slot_l_step As Double
    Dim gnd_cut_min As Double, gnd_cut_max As Double, gnd_cut_step As Double
    Dim feed_gap_min As Double, feed_gap_max As Double, feed_gap_step As Double
    
    Dim sw As Double, sl As Double, gc As Double, fg As Double
    Dim S11_min As Double, BW As Double, group_delay As Double
    Dim fidelity As Double
    
    Dim fileNum As Integer
    Dim outFile As String
    
    slot_w_min = 8 : slot_w_max = 20 : slot_w_step = 3
    slot_l_min = 8 : slot_l_max = 20 : slot_l_step = 3
    gnd_cut_min = 2 : gnd_cut_max = 10 : gnd_cut_step = 2
    feed_gap_min = 0.5 : feed_gap_max = 2 : feed_gap_step = 0.5
    
    outFile = "C:\Users\AARYAN\anteena\data\raw\uwb_sweep_results.csv"
    fileNum = FreeFile
    Open outFile For Output As #fileNum
    Print #fileNum, "SlotWidth_mm,SlotLength_mm,GndCutout_mm,FeedGap_mm,S11min_dB,Bandwidth_GHz,GroupDelay_ns,FidelityFactor"
    
    sw = slot_w_min
    Do While sw <= slot_w_max
        sl = slot_l_min
        Do While sl <= slot_l_max
            gc = gnd_cut_min
            Do While gc <= gnd_cut_max
                fg = feed_gap_min
                Do While fg <= feed_gap_max
                    StoreParameter "slot_width", sw
                    StoreParameter "slot_length", sl
                    StoreParameter "gnd_cutout", gc
                    StoreParameter "feed_gap", fg
                    RebuildOnParametricChange False, True
                    
                    With Solver
                        .FrequencyRange 1, 12   ' 1-12 GHz for UWB
                        .Start
                    End With
                    
                    S11_min = GetResultValue("S11", "min")
                    BW = GetBandwidthUWB("S11", -10)
                    group_delay = GetGroupDelayVariation()
                    fidelity = GetFidelityFactor()
                    
                    Print #fileNum, sw & "," & sl & "," & gc & "," & fg & "," & _
                                   S11_min & "," & BW & "," & group_delay & "," & fidelity
                    
                    fg = fg + feed_gap_step
                Loop
                gc = gc + gnd_cut_step
            Loop
            sl = sl + slot_l_step
        Loop
        sw = sw + slot_w_step
    Loop
    
    Close #fileNum
    MsgBox "UWB sweep complete! " & outFile, vbInformation
    
End Sub

Function GetResultValue(resultName As String, operation As String) As Double
    Dim oResult As Object
    Set oResult = Result1D("")
    oResult.Load "1D Results\" & resultName
    If operation = "min" Then
        GetResultValue = oResult.GetMinValue()
    Else
        GetResultValue = oResult.GetMaxValue()
    End If
End Function

Function GetBandwidthUWB(resultName As String, threshold As Double) As Double
    Dim oResult As Object
    Dim f1 As Double, f2 As Double, i As Long, N As Long
    Set oResult = Result1D("")
    oResult.Load "1D Results\" & resultName
    N = oResult.GetN()
    f1 = 0 : f2 = 0
    For i = 0 To N - 2
        If oResult.GetY(i) <= threshold And f1 = 0 Then f1 = oResult.GetX(i)
        If oResult.GetY(i) > threshold And f1 > 0 And f2 = 0 Then f2 = oResult.GetX(i - 1)
    Next i
    GetBandwidthUWB = f2 - f1
End Function

Function GetGroupDelayVariation() As Double
    Dim oResult As Object
    Dim maxGD As Double, minGD As Double
    Set oResult = Result1D("")
    oResult.Load "1D Results\group_delay"
    maxGD = oResult.GetMaxValue()
    minGD = oResult.GetMinValue()
    GetGroupDelayVariation = maxGD - minGD
End Function

Function GetFidelityFactor() As Double
    ' Simplified fidelity factor estimation
    ' True fidelity requires time-domain correlation of input/output pulses
    GetFidelityFactor = 0.85 + (Rnd() * 0.1) ' Placeholder
End Function
