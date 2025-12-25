<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8" />
</head>
<body style="margin:0;padding:0;background:#d1d5db;font-family:Inter,Arial,sans-serif;">
  <table width="100%" cellpadding="0" cellspacing="0">
    <tr>
      <td align="center" style="padding:40px 16px;">
        <table width="420" style="background:#ffffff;border-radius:16px;padding:32px;">
          <tr>
            <td align="center">
              <div style="width:80px;height:80px;border-radius:50%;background:#e9d5ff;font-size:40px;line-height:80px;">
                🦙
              </div>
              <h2 style="color:#312e81;margin:24px 0 8px;">
                Reset your password
              </h2>
              <p style="color:#6b7280;font-size:14px;">
                Click the button below to reset your DalaiLLAMA password.
              </p>
              <a href="${link}"
                 style="display:inline-block;margin-top:24px;padding:12px 24px;
                        background:#2563eb;color:#ffffff;
                        text-decoration:none;border-radius:8px;font-weight:700;">
                Reset Password
              </a>
              <p style="margin-top:24px;font-size:12px;color:#9ca3af;">
                If you didn’t request this, you can safely ignore this email.
              </p>
              <p style="margin-top:32px;font-size:12px;color:#9ca3af;">
                ${msg("emailSignature")}
              </p>
            </td>
          </tr>
        </table>
      </td>
    </tr>
  </table>
</body>
</html>
