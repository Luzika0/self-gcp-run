package main

import (
	"crypto/subtle"
	"html/template"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"strings"
	"time"
)

const loginPage = `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Service Information</title><style>
*{box-sizing:border-box}body{margin:0;min-height:100vh;display:grid;place-items:center;padding:24px;background:#0b1120;color:#e5e7eb;font:16px system-ui}.card{width:min(100%,440px);padding:32px;border:1px solid #334155;border-radius:22px;background:#111827;box-shadow:0 24px 70px #0006}h1{margin:0 0 10px}p{color:#aab7ca;line-height:1.6}input,button{width:100%;padding:14px;border-radius:11px;font:inherit}input{margin:12px 0;background:#0b1120;border:1px solid #475569;color:white}button{border:0;background:#38bdf8;color:#082f49;font-weight:700;cursor:pointer}.error{color:#fca5a5}.tag{color:#7dd3fc;font-size:12px;letter-spacing:.15em;text-transform:uppercase}</style></head><body><main class="card"><div class="tag">Private access</div><h1>Service Information</h1><p>Enter your access UUID to view service information.</p>{{if .Error}}<p class="error">{{.Error}}</p>{{end}}<form method="post" action="/verify"><input type="password" name="uuid" placeholder="Enter UUID" minlength="36" maxlength="36" required autocomplete="off"><button>Verify access</button></form></main></body></html>`
const infoPage = `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Service Information</title><style>body{margin:0;min-height:100vh;display:grid;place-items:center;padding:24px;background:#0b1120;color:#e5e7eb;font:16px system-ui}.card{max-width:560px;padding:32px;border:1px solid #334155;border-radius:22px;background:#111827}p{color:#aab7ca;line-height:1.7}.status{color:#86efac}</style></head><body><main class="card"><h1>Service Information</h1><p class="status">● Access verified</p><p>Your web endpoint is responding.</p><p>Proxy transport: VLESS over WebSocket.</p><p>Use the WebSocket path configured in your client. This page does not display your UUID.</p></main></body></html>`

var login = template.Must(template.New("login").Parse(loginPage))

func main() {
	uuid := strings.TrimSpace(os.Getenv("VLESS_UUID"))
	if uuid == "" { log.Fatal("VLESS_UUID must be configured") }
	path := os.Getenv("WS_PATH")
	if path == "" { path = "/" }
	port := os.Getenv("XRAY_PORT")
	if port == "" { port = "8081" }
	target, err := url.Parse("http://127.0.0.1:" + port)
	if err != nil { log.Fatal(err) }
	proxy := httputil.NewSingleHostReverseProxy(target)
	proxy.ErrorHandler = func(w http.ResponseWriter, r *http.Request, err error) {
		log.Printf("Xray proxy error: %v", err)
		http.Error(w, "Proxy temporarily unavailable", http.StatusBadGateway)
	}

	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if strings.EqualFold(r.Header.Get("Upgrade"), "websocket") {
			if r.URL.Path != path { http.NotFound(w, r); return }
			proxy.ServeHTTP(w, r)
			return
		}
		w.Header().Set("Cache-Control", "no-store")
		switch {
		case r.URL.Path == "/" && r.Method == http.MethodGet:
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			_ = login.Execute(w, struct{ Error string }{})
		case r.URL.Path == "/verify" && r.Method == http.MethodPost:
			r.Body = http.MaxBytesReader(w, r.Body, 1024)
			if err := r.ParseForm(); err != nil { http.Error(w, "Invalid request", http.StatusBadRequest); return }
			got := strings.TrimSpace(r.FormValue("uuid"))
			if len(got) != len(uuid) || subtle.ConstantTimeCompare([]byte(got), []byte(uuid)) != 1 {
				w.Header().Set("Content-Type", "text/html; charset=utf-8")
				w.WriteHeader(http.StatusUnauthorized)
				_ = login.Execute(w, struct{ Error string }{Error: "Incorrect UUID. Please try again."})
				return
			}
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			_, _ = w.Write([]byte(infoPage))
		default:
			http.NotFound(w, r)
		}
	})
	webPort := os.Getenv("PORT")
	if webPort == "" { webPort = "8080" }
	server := &http.Server{Addr: ":" + webPort, Handler: http.DefaultServeMux, ReadHeaderTimeout: 10 * time.Second}
	log.Printf("Web gateway listening on :%s", webPort)
	log.Fatal(server.ListenAndServe())
}
