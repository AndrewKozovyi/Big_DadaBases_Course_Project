// Script Task «Оцінка якості ETL» (пакет Rental_ETL.dtsx, між «Звірка» та «Завершення ETL»).
// ReadOnlyVariables:  User::RunID, User::DiffInvoices, User::DiffPayments, User::ErrorRows
// ReadWriteVariables: User::RunStatus, User::RunMessage
//
// Бізнес-правила оцінки запуску:
//   • розбіжностей немає і відбракованих рядків немає           -> Success;
//   • розбіжність повністю пояснюється відбракованими рядками
//     (вони записані в ETL_ErrorRow) і їх частка не більша 1 %   -> Warning;
//   • розбіжність без пояснення або відбраковано понад 1 %       -> Failed: задача завершується з помилкою,
//     обробник OnError записує її в ETL_ErrorLog і позначає запуск як Failed.
// У ScriptMain.cs замініть метод Main() на код нижче.

public void Main()
{
    int runId        = (int)Dts.Variables["User::RunID"].Value;
    int diffInvoices = (int)Dts.Variables["User::DiffInvoices"].Value;
    int diffPayments = (int)Dts.Variables["User::DiffPayments"].Value;
    int errorRows    = (int)Dts.Variables["User::ErrorRows"].Value;

    int totalDiff = diffInvoices + diffPayments;      // скільки рядків джерела не потрапило у факти
    const double MaxErrorShare = 0.01;                // допустима частка відбракованих рядків — 1 %
    const int ApproxSourceRows = 450000;              // орієнтовний обсяг фактів у джерелі

    string details = string.Format(
        "Запуск {0}: розбіжність рахунків {1}, платежів {2}, відбраковано рядків {3}.",
        runId, diffInvoices, diffPayments, errorRows);

    string status;
    if (totalDiff == 0 && errorRows == 0)
    {
        status = "Success";
        details += " Звірка пройдена.";
    }
    else if (totalDiff == errorRows && errorRows <= ApproxSourceRows * MaxErrorShare)
    {
        status = "Warning";
        details += " Розбіжність пояснюється відбракованими рядками (див. ETL_ErrorRow).";
        Dts.Events.FireWarning(0, "Оцінка якості ETL", details, string.Empty, 0);
    }
    else
    {
        status = "Failed";
        details += " Розбіжність не пояснюється відбракованими рядками або перевищує 1 %.";
    }

    Dts.Variables["User::RunStatus"].Value  = status;
    Dts.Variables["User::RunMessage"].Value = details;

    bool fireAgain = false;
    Dts.Events.FireInformation(0, "Оцінка якості ETL", details, string.Empty, 0, ref fireAgain);

    if (status == "Failed")
    {
        Dts.Events.FireError(0, "Оцінка якості ETL", details, string.Empty, 0);
        Dts.TaskResult = (int)ScriptResults.Failure;
        return;
    }

    Dts.TaskResult = (int)ScriptResults.Success;
}
