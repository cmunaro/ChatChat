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
          .live-messages-section { width: 100%; margin-top: 16px; border: 1px solid #253143; border-radius: 18px; background: rgba(13,20,31,.82); overflow: hidden; }
          .live-messages-summary { width: 100%; display: flex; align-items: center; justify-content: space-between; gap: 24px; padding: 24px 26px; border: 0; background: transparent; color: inherit; font: inherit; text-align: left; cursor: pointer; user-select: none; }
          .live-messages-summary:hover { background: rgba(37,49,67,.22); }
          .live-messages-title { display: flex; align-items: center; gap: 15px; }
          .live-messages-title .eyebrow { margin-bottom: 5px; }
          .live-messages-title h2 { margin: 0; font-size: 24px; letter-spacing: -.025em; }
          .disclosure-icon { width: 10px; height: 10px; border-right: 2px solid #6ee7b7; border-bottom: 2px solid #6ee7b7; transform: rotate(-45deg); transition: transform .18s ease; }
          .disclosure-icon.open { transform: rotate(45deg) translate(-2px, -2px); }
          .stream-state { display: flex; align-items: center; gap: 9px; color: #91a0b5; font-size: 12px; white-space: nowrap; }
          .message-graph { min-height: 360px; border-top: 1px solid #253143; display: grid; place-items: center; background-color: #0a111b; background-image: radial-gradient(circle, rgba(110,231,183,.13) 1px, transparent 1px); background-size: 24px 24px; }
          .graph-empty-state { max-width: 390px; padding: 54px 24px; text-align: center; }
          .empty-node { width: 58px; height: 58px; margin: 0 auto 18px; display: grid; place-items: center; border: 1px solid #31506a; border-radius: 50%; background: #111d2a; color: #6ee7b7; box-shadow: 0 0 35px rgba(52,211,153,.1); }
          .graph-empty-state h3 { margin: 0; font-size: 18px; }
          .graph-empty-state p { margin: 9px 0 0; color: #68778d; font-size: 13px; line-height: 1.55; }
          .message-flows { width: 100%; padding: 30px; display: grid; grid-template-columns: repeat(auto-fit, minmax(330px, 1fr)); gap: 18px; }
          .message-flow { min-width: 0; display: grid; grid-template-columns: 88px minmax(100px, 1fr) 88px; align-items: center; gap: 12px; padding: 20px; border: 1px solid #253143; border-radius: 16px; background: rgba(13,20,31,.92); }
          .client-node { width: 82px; height: 82px; position: relative; display: flex; flex-direction: column; align-items: center; justify-content: center; border: 1px solid #31506a; border-radius: 50%; background: #111d2a; text-align: center; }
          .client-node strong { max-width: 66px; overflow: hidden; color: #edf2f7; font-size: 15px; text-overflow: ellipsis; }
          .client-node small { color: #68778d; font-size: 9px; text-transform: uppercase; }
          .client-state { position: absolute; top: 5px; right: 5px; width: 10px; height: 10px; border: 2px solid #111d2a; border-radius: 50%; }
          .client-state.online { background: #34d399; }
          .client-state.unknown { background: #64748b; }
          .message-directions { min-width: 0; display: flex; flex-direction: column; justify-content: center; gap: 24px; }
          .message-edge { position: relative; display: flex; align-items: center; min-width: 0; }
          .message-edge.direction-left { flex-direction: row; }
          .edge-line { width: 100%; height: 2px; background: #526176; animation: message-shot 1.8s ease-out forwards; }
          .edge-arrow { color: #526176; font-size: 30px; line-height: 0; animation: arrow-shot 1.8s ease-out forwards; }
          .direction-right .edge-arrow { margin-left: -3px; }
          .direction-left .edge-arrow { margin-right: -3px; }
          .edge-count { position: absolute; left: 50%; bottom: 10px; min-width: 25px; padding: 3px 7px; border: 1px solid #304158; border-radius: 999px; background: #111d2a; color: #cbd5e1; font-size: 11px; text-align: center; transform: translateX(-50%); }
          @keyframes message-shot { 0%, 35% { background: #6ee7b7; box-shadow: 0 0 12px #34d399; } 100% { background: #526176; box-shadow: none; } }
          @keyframes arrow-shot { 0%, 35% { color: #6ee7b7; text-shadow: 0 0 12px #34d399; } 100% { color: #526176; text-shadow: none; } }
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
          .protocol-intro { margin-bottom: 24px; padding: 20px 22px; border: 1px solid #253143; border-radius: 14px; background: rgba(13,20,31,.76); color: #a7b3c4; line-height: 1.6; }
          .protocol-intro code { color: #6ee7b7; }
          .protocol-group { margin-top: 26px; }
          .protocol-group h2 { margin: 0 0 12px; font-size: 22px; }
          .protocol-frame { margin-bottom: 10px; border: 1px solid #253143; border-radius: 12px; overflow: hidden; background: rgba(13,20,31,.82); }
          .protocol-frame summary { display: grid; grid-template-columns: 150px 130px 1fr; align-items: center; gap: 16px; padding: 17px 20px; cursor: pointer; list-style: none; }
          .protocol-frame summary::-webkit-details-marker { display: none; }
          .protocol-frame summary::after { content: '\203A'; justify-self: end; color: #6ee7b7; font-size: 26px; transition: transform .15s ease; }
          .protocol-frame[open] summary::after { transform: rotate(90deg); }
          .protocol-name { color: #edf2f7; font-weight: 750; }
          .protocol-direction { width: fit-content; padding: 4px 8px; border-radius: 999px; background: #19334d; color: #93c5fd; font-size: 11px; font-weight: 750; text-transform: uppercase; }
          .protocol-purpose { color: #91a0b5; font-size: 13px; }
          .protocol-body { padding: 0 20px 20px; border-top: 1px solid #253143; }
          .protocol-body pre { margin: 18px 0 0; padding: 16px; overflow-x: auto; border-radius: 10px; background: #070b11; color: #a7f3d0; font-size: 13px; line-height: 1.55; }
          .sr-only { position: absolute; width: 1px; height: 1px; padding: 0; margin: -1px; overflow: hidden; clip: rect(0,0,0,0); white-space: nowrap; border: 0; }
          @media (max-width: 900px) { .metric-grid { grid-template-columns: repeat(2, 1fr); } }
          @media (max-width: 560px) { .admin-shell { width: min(100% - 24px, 1180px); padding: 40px 0; } .page-header, .section-heading { align-items: start; flex-direction: column; } .header-actions { align-items: start; flex-direction: column; } .metric-grid { grid-template-columns: 1fr; } .live-messages-summary { align-items: start; flex-direction: column; } .message-graph { min-height: 300px; } .message-flows { padding: 16px; grid-template-columns: 1fr; } .message-flow { grid-template-columns: 74px minmax(70px, 1fr) 74px; padding: 14px; } .client-node { width: 70px; height: 70px; } .search-form { flex-direction: column; } .protocol-frame summary { grid-template-columns: 1fr auto; } .protocol-purpose { grid-column: 1 / -1; } }
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
