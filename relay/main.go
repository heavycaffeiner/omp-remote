package main

import (
	"context"
	"crypto/subtle"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"
)

// extractToken reads the bearer token from the Authorization header,
// falling back to a token query parameter for clients that cannot set
// headers on a WebSocket upgrade request.
func extractToken(r *http.Request) string {
	if h := r.Header.Get("Authorization"); h != "" {
		if after, ok := strings.CutPrefix(h, "Bearer "); ok {
			return after
		}
		return ""
	}
	return r.URL.Query().Get("token")
}

// constantTimeEqual compares two tokens in constant time. An empty want
// never matches, so a disabled token cannot be satisfied by an empty
// presented value.
func constantTimeEqual(got, want string) bool {
	if want == "" {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(got), []byte(want)) == 1
}

func checkAgentAuth(r *http.Request, agentToken string) bool {
	got := extractToken(r)
	return constantTimeEqual(got, agentToken)
}

// checkClientAuth derives the connection's role from which token matched.
// Both candidate tokens are always compared, even after a match, so
// response timing cannot reveal which one it was.
func checkClientAuth(r *http.Request, controlToken, viewerToken string) (Role, bool) {
	got := extractToken(r)
	controlMatch := constantTimeEqual(got, controlToken)
	viewerMatch := viewerToken != "" && constantTimeEqual(got, viewerToken)
	switch {
	case controlMatch:
		return RoleControl, true
	case viewerMatch:
		return RoleViewer, true
	default:
		return "", false
	}
}

func healthzHandler(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
	w.Write([]byte("ok"))
}

// runHealthcheck dials /healthz on the given address and exits 0 or 1. It
// backs the -healthcheck flag used as the Docker Compose healthcheck
// command, since the distroless final image has no shell and no curl.
func runHealthcheck(addr string) int {
	client := http.Client{Timeout: 3 * time.Second}
	resp, err := client.Get(fmt.Sprintf("http://%s/healthz", addr))
	if err != nil {
		return 1
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return 1
	}
	return 0
}

func main() {
	addr := flag.String("addr", envOr("OMP_RELAY_ADDR", ":8787"), "listen address")
	healthcheck := flag.Bool("healthcheck", false, "dial /healthz on -addr and exit 0 or 1, for use as a container healthcheck")
	flag.Parse()

	if *healthcheck {
		os.Exit(runHealthcheck(dialAddr(*addr)))
	}

	agentToken := os.Getenv("OMP_RELAY_AGENT_TOKEN")
	controlToken := os.Getenv("OMP_RELAY_CONTROL_TOKEN")
	viewerToken := os.Getenv("OMP_RELAY_VIEWER_TOKEN")

	if agentToken == "" {
		log.Fatal("OMP_RELAY_AGENT_TOKEN is required and must not be empty")
	}
	if controlToken == "" {
		log.Fatal("OMP_RELAY_CONTROL_TOKEN is required and must not be empty")
	}

	hub := NewHub()

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", healthzHandler)
	mux.Handle("/agent", agentHandler(hub, agentToken))
	mux.Handle("/client", clientHandler(hub, controlToken, viewerToken))

	server := &http.Server{
		Addr:    *addr,
		Handler: mux,
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	go func() {
		log.Printf("relay listening on %s", *addr)
		if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("relay: listen: %v", err)
		}
	}()

	<-ctx.Done()
	log.Print("relay: shutting down")

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := server.Shutdown(shutdownCtx); err != nil {
		log.Printf("relay: shutdown: %v", err)
	}
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// dialAddr turns a listen address into one dialable on localhost: an
// address like ":8787" has no host to connect to.
func dialAddr(addr string) string {
	host, port, err := net.SplitHostPort(addr)
	if err != nil {
		return addr
	}
	if host == "" || host == "0.0.0.0" || host == "::" {
		host = "127.0.0.1"
	}
	return net.JoinHostPort(host, port)
}
