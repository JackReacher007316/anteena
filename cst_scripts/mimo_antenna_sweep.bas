'==============================================================================
' CST VBA Macro: MIMO Antenna Parameter Sweep
' Description: Sweeps MIMO element spacing and evaluates isolation, ECC, TARC
'==============================================================================

Option Explicit

Sub MIMOAntennaSweep()

    Dim spacing_min As Double, spacing_max As Double, spacing_step As Double
    Dim len_min As Double, len_max As Double, len_step As Double
    
    Dim spacing As Double, antenna_len As Double
    Dim S11 As Double, S21 As Double, ECC As Double, TARC As Double
    
    Dim fileNum As Integer
    Dim outFile As String
    
    spacing_min = 0.05  ' Lambda units (normalized)
    spacing_max = 0.5
    spacing_step = 0.025
    len_min = 15 : len_max = 35 : len_step = 5
    
    outFile = "C:\Users\AARYAN\anteena\data\raw\mimo_sweep_results.csv"
    fileNum = FreeFile
    Open outFile For Output As #fileNum
    Print #fileNum, "Spacing_lambda,Length_mm,S11_dB,S21_dB,Isolation_dB,ECC,TARC_dB"
    
    spacing = spacing_min
    Do While spacing <= spacing_max
        antenna_len = len_min
        Do While antenna_len <= len_max
            StoreParameter "element_spacing_norm", spacing
            StoreParameter "element_length", antenna_len
            RebuildOnParametricChange False, True
            
            With Solver
                .Start
            End With
            
            S11 = GetResultValue("S11", "min")
            S21 = GetIsolation("S21")
            ECC = CalculateECC()
            TARC = CalculateTARC(S11, S21)
            
            Print #fileNum, spacing & "," & antenna_len & "," & S11 & "," & _
                           S21 & "," & Abs(S21) & "," & ECC & "," & TARC
            
            antenna_len = antenna_len + len_step
        Loop
        spacing = spacing + spacing_step
    Loop
    
    Close #fileNum
    MsgBox "MIMO sweep complete! Results saved to: " & outFile, vbInformation
    
End Sub

Function GetIsolation(resultName As String) As Double
    Dim oResult As Object
    Set oResult = Result1D("")
    oResult.Load "1D Results\" & resultName
    GetIsolation = oResult.GetMinValue()
End Function

Function CalculateECC() As Double
    ' Envelope Correlation Coefficient from S-parameters
    ' ECC = |S11*S12 + S21*S22|^2 / ((1-|S11|^2-|S21|^2)(1-|S22|^2-|S12|^2))
    ' Simplified: Using S-parameter method
    Dim S11 As Double, S12 As Double, S21 As Double, S22 As Double
    S11 = 10 ^ (GetResultValue("S11", "min") / 20)
    S12 = 10 ^ (GetResultValue("S12", "min") / 20)
    S21 = 10 ^ (GetResultValue("S21", "min") / 20)
    S22 = 10 ^ (GetResultValue("S22", "min") / 20)
    
    Dim numerator As Double, denom As Double
    numerator = (S11 * S12 + S21 * S22) ^ 2
    denom = (1 - S11 ^ 2 - S21 ^ 2) * (1 - S22 ^ 2 - S12 ^ 2)
    If denom > 0 Then
        CalculateECC = numerator / denom
    Else
        CalculateECC = 1
    End If
End Function

Function CalculateTARC(S11 As Double, S21 As Double) As Double
    ' Total Active Reflection Coefficient (2-port)
    Dim s11_lin As Double, s21_lin As Double
    s11_lin = 10 ^ (S11 / 20)
    s21_lin = 10 ^ (S21 / 20)
    CalculateTARC = 20 * Log(Sqr((s11_lin ^ 2 + s21_lin ^ 2) / 2)) / Log(10)
End Function
