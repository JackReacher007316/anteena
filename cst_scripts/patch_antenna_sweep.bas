'==============================================================================
' CST VBA Macro: Patch Antenna Parameter Sweep
' Author: ML Antenna Framework
' Description: Sweeps patch antenna dimensions and exports S11, Gain, BW
'==============================================================================

Option Explicit

Sub PatchAntennaSweep()

    Dim sProject As String
    Dim L_min As Double, L_max As Double, L_step As Double
    Dim W_min As Double, W_max As Double, W_step As Double
    Dim h_min As Double, h_max As Double, h_step As Double
    Dim er_list(4) As Double
    
    Dim L As Double, W As Double, h As Double
    Dim er_idx As Integer
    Dim er As Double
    
    Dim fileNum As Integer
    Dim outFile As String
    Dim S11 As Double, Gain As Double, BW As Double, Freq As Double
    
    ' ---- Sweep ranges (in mm) ----
    L_min = 10 : L_max = 40 : L_step = 5
    W_min = 10 : W_max = 40 : W_step = 5
    h_min = 0.5 : h_max = 3.0 : h_step = 0.5
    er_list(0) = 2.2  ' Rogers RT/Duroid 5880
    er_list(1) = 3.5  ' FR-4 (nominal)
    er_list(2) = 4.4  ' FR-4
    er_list(3) = 6.15 ' Rogers RO3006
    er_list(4) = 9.8  ' Alumina
    
    ' ---- Output file ----
    outFile = "C:\Users\AARYAN\anteena\data\raw\patch_sweep_results.csv"
    fileNum = FreeFile
    Open outFile For Output As #fileNum
    Print #fileNum, "Length_mm,Width_mm,Height_mm,Permittivity,S11_dB,Gain_dBi,Bandwidth_GHz,Resonant_Freq_GHz"
    
    ' ---- Main sweep loop ----
    L = L_min
    Do While L <= L_max
        W = W_min
        Do While W <= W_max
            h = h_min
            Do While h <= h_max
                For er_idx = 0 To 4
                    er = er_list(er_idx)
                    
                    ' Update CST model parameters
                    StoreParameter "patch_length", L
                    StoreParameter "patch_width", W
                    StoreParameter "sub_height", h
                    StoreParameter "sub_permittivity", er
                    
                    ' Rebuild and simulate
                    RebuildOnParametricChange False, True
                    
                    Dim oSolver As Object
                    Set oSolver = CreateObject("CSTStudio.Application")
                    
                    ' Run frequency domain solver
                    With Solver
                        .Start
                    End With
                    
                    ' Extract S11 at resonance
                    Dim oResult As Object
                    S11 = GetResultValue("S11", "min")   ' Minimum S11 (dB)
                    Freq = GetResonantFrequency("S11")   ' Resonant frequency
                    Gain = GetResultValue("farfield_gain", "max")
                    BW = GetBandwidth("S11", -10)        ' -10 dB bandwidth
                    
                    ' Write to CSV
                    Print #fileNum, L & "," & W & "," & h & "," & er & "," & _
                                    S11 & "," & Gain & "," & BW & "," & Freq
                    
                Next er_idx
                h = h + h_step
            Loop
            W = W + W_step
        Loop
        L = L + L_step
    Loop
    
    Close #fileNum
    MsgBox "Patch antenna sweep complete! Results saved to: " & outFile, vbInformation
    
End Sub

'==============================================================================
' Helper: Get minimum value from a 1D result
'==============================================================================
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

'==============================================================================
' Helper: Find resonant frequency (frequency of minimum S11)
'==============================================================================
Function GetResonantFrequency(resultName As String) As Double
    Dim oResult As Object
    Set oResult = Result1D("")
    oResult.Load "1D Results\" & resultName
    GetResonantFrequency = oResult.GetX(oResult.GetMinIndex())
End Function

'==============================================================================
' Helper: Calculate -10 dB bandwidth
'==============================================================================
Function GetBandwidth(resultName As String, threshold As Double) As Double
    Dim oResult As Object
    Dim f1 As Double, f2 As Double
    Dim i As Long, N As Long
    Dim val As Double
    Set oResult = Result1D("")
    oResult.Load "1D Results\" & resultName
    N = oResult.GetN()
    f1 = 0 : f2 = 0
    For i = 0 To N - 2
        val = oResult.GetY(i)
        If val <= threshold And f1 = 0 Then f1 = oResult.GetX(i)
        If val > threshold And f1 > 0 And f2 = 0 Then f2 = oResult.GetX(i - 1)
    Next i
    GetBandwidth = f2 - f1
End Function
