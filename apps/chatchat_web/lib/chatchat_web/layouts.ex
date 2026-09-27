defmodule ChatchatWeb.Layouts do
  @moduledoc false

  use Phoenix.Component

  attr :inner_content, :any, required: true

  def app(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <title>ChatChat Admin</title>
        <style>
          :root { color-scheme: dark; font-family: Inter, ui-sans-serif, system-ui, sans-serif; background: #090d14; color: #edf2f7; }
          * { box-sizing: border-box; }
          body { margin: 0; min-height: 100vh; background: radial-gradient(circle at 50% -20%, #19334d 0, #0d1622 34%, #090d14 68%); }
          .admin-shell { width: min(1180px, calc(100% - 40px)); margin: 0 auto; padding: 72px 0; }
          .page-header { display: flex; align-items: end; justify-content: space-between; gap: 32px; margin-bottom: 36px; }
          .eyebrow { margin: 0 0 10px; color: #6ee7b7; font-size: 12px; font-weight: 800; letter-spacing: .14em; text-transform: uppercase; }
          h1 { margin: 0; font-size: clamp(36px, 6vw, 64px); letter-spacing: -.055em; line-height: .95; }
          .subtitle { margin: 18px 0 0; color: #91a0b5; font-size: 17px; }
          .live-status { display: flex; align-items: center; gap: 9px; white-space: nowrap; color: #91a0b5; font-size: 13px; }
          .header-actions { display: flex; align-items: center; gap: 16px; }
          .logout-button { padding: 8px 12px; border: 1px solid #304158; border-radius: 9px; background: transparent; color: #a7b3c4; cursor: pointer; }
          .logout-button:hover { border-color: #6ee7b7; color: #edf2f7; }
          .status-dot { width: 9px; height: 9px; border-radius: 50%; background: #34d399; box-shadow: 0 0 16px #34d399; }
          .metric-grid { display: grid; grid-template-columns: repeat(4, 1fr); gap: 14px; }
          .metric-card { min-height: 220px; padding: 24px; border: 1px solid #253143; border-radius: 18px; background: linear-gradient(145deg, rgba(24,34,49,.95), rgba(13,20,31,.92)); box-shadow: 0 20px 60px rgba(0,0,0,.22); }
          .metric-label { margin: 0; color: #a7b3c4; font-size: 14px; font-weight: 650; }
          .metric-value { margin: 36px 0 30px; color: #f8fafc; font-size: clamp(42px, 6vw, 68px); font-weight: 750; letter-spacing: -.06em; line-height: 1; }
          .metric-value.unavailable { color: #fbbf24; font-size: 24px; letter-spacing: -.02em; }
          .metric-detail { margin: 0; color: #68778d; font-size: 12px; line-height: 1.5; }
          .users-section { margin-top: 16px; padding: 26px; border: 1px solid #253143; border-radius: 18px; background: rgba(13,20,31,.76); }
          .section-heading { display: flex; align-items: end; justify-content: space-between; gap: 20px; }
          .section-heading h2 { margin: 0; font-size: 24px; letter-spacing: -.025em; }
          .section-heading > p { margin: 0; color: #68778d; font-size: 12px; }
          .search-form { display: flex; gap: 10px; margin-top: 22px; }
          .search-form input { flex: 1; min-width: 0; padding: 12px 14px; border: 1px solid #304158; border-radius: 10px; outline: none; background: #0b121d; color: #f8fafc; font: inherit; }
          .search-form input:focus { border-color: #34d399; box-shadow: 0 0 0 3px rgba(52,211,153,.12); }
          .search-form button { padding: 12px 20px; border: 0; border-radius: 10px; background: #34d399; color: #052e24; font: inherit; font-weight: 800; cursor: pointer; }
          .search-message { margin: 18px 0 0; color: #91a0b5; font-size: 13px; }
          .search-message.error { color: #fca5a5; }
          .users-table-wrapper { margin-top: 22px; overflow-x: auto; }
          table { width: 100%; border-collapse: collapse; }
          th, td { padding: 13px 12px; border-bottom: 1px solid #253143; text-align: left; }
          th { color: #68778d; font-size: 11px; letter-spacing: .1em; text-transform: uppercase; }
          td { color: #cbd5e1; font-size: 14px; }
          .sr-only { position: absolute; width: 1px; height: 1px; padding: 0; margin: -1px; overflow: hidden; clip: rect(0,0,0,0); white-space: nowrap; border: 0; }
          @media (max-width: 900px) { .metric-grid { grid-template-columns: repeat(2, 1fr); } }
          @media (max-width: 560px) { .admin-shell { width: min(100% - 24px, 1180px); padding: 40px 0; } .page-header, .section-heading { align-items: start; flex-direction: column; } .header-actions { align-items: start; flex-direction: column; } .metric-grid { grid-template-columns: 1fr; } .search-form { flex-direction: column; } }
        </style>
      </head>
      <body>
        <%= @inner_content %>
        <script src="/assets/phoenix/phoenix.min.js"></script>
        <script src="/assets/live_view/phoenix_live_view.min.js"></script>
        <script>
          const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");
          const liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {params: {_csrf_token: csrfToken}});
          liveSocket.connect();
          window.liveSocket = liveSocket;
        </script>
      </body>
    </html>
    """
  end
end
