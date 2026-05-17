package main

import (
	"context"
	"errors"
	"log"
	"math"
	"math/rand"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

var (
	httpRequestsTotal = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Name: "shop_api_http_requests_total",
			Help: "Total HTTP requests partitioned by route and status code.",
		},
		[]string{"route", "code", "method"},
	)
	httpRequestDuration = prometheus.NewHistogramVec(
		prometheus.HistogramOpts{
			Name:    "shop_api_http_request_duration_seconds",
			Help:    "HTTP request latency in seconds, partitioned by route.",
			Buckets: prometheus.ExponentialBucketsRange(0.005, 5, 12),
		},
		[]string{"route"},
	)
	inFlight = prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "shop_api_inflight_requests",
		Help: "Number of in-flight HTTP requests.",
	})
)

func init() {
	prometheus.MustRegister(httpRequestsTotal, httpRequestDuration, inFlight)
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (s *statusRecorder) WriteHeader(code int) {
	s.status = code
	s.ResponseWriter.WriteHeader(code)
}

func observe(route string, h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		inFlight.Inc()
		defer inFlight.Dec()
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		h(rec, r)
		dur := time.Since(start).Seconds()
		httpRequestDuration.WithLabelValues(route).Observe(dur)
		httpRequestsTotal.WithLabelValues(route, strconv.Itoa(rec.status), r.Method).Inc()
	}
}

func indexHandler(w http.ResponseWriter, r *http.Request) {
	host, _ := os.Hostname()
	w.Header().Set("Content-Type", "application/json")
	_, _ = w.Write([]byte(`{"service":"shop-api","hostname":"` + host + `","version":"` + getEnv("APP_VERSION", "v1") + `"}`))
}

func healthHandler(w http.ResponseWriter, _ *http.Request) {
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ok"))
}

func readyHandler(w http.ResponseWriter, _ *http.Request) {
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ready"))
}

func workHandler(w http.ResponseWriter, r *http.Request) {
	iters := 200_000
	if q := r.URL.Query().Get("iters"); q != "" {
		if n, err := strconv.Atoi(q); err == nil && n > 0 && n <= 5_000_000 {
			iters = n
		}
	}
	acc := 0.0
	for i := 1; i <= iters; i++ {
		acc += math.Sqrt(float64(i)) * math.Log1p(float64(i))
	}
	w.Header().Set("Content-Type", "application/json")
	_, _ = w.Write([]byte(`{"iters":` + strconv.Itoa(iters) + `,"result":` + strconv.FormatFloat(acc, 'g', -1, 64) + `}`))
}

func errorHandler(w http.ResponseWriter, _ *http.Request) {
	if rand.Float64() < 0.5 {
		http.Error(w, "boom", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_, _ = w.Write([]byte(`{"ok":true}`))
}

func main() {
	port := getEnv("APP_PORT", "5000")

	mux := http.NewServeMux()
	mux.Handle("/metrics", promhttp.Handler())
	mux.HandleFunc("/healthz", observe("/healthz", healthHandler))
	mux.HandleFunc("/ready", observe("/ready", readyHandler))
	mux.HandleFunc("/work", observe("/work", workHandler))
	mux.HandleFunc("/error", observe("/error", errorHandler))
	mux.HandleFunc("/", observe("/", indexHandler))

	srv := &http.Server{
		Addr:         ":" + port,
		Handler:      mux,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 30 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, os.Interrupt, syscall.SIGTERM)

	errCh := make(chan error, 1)
	go func() {
		log.Printf("shop-api listening on :%s", port)
		errCh <- srv.ListenAndServe()
	}()

	select {
	case sig := <-sigCh:
		log.Printf("received signal %s, shutting down", sig)
	case err := <-errCh:
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Printf("server stopped with error: %v", err)
		}
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_ = srv.Shutdown(ctx)
	log.Printf("shop-api shutdown complete")
}

func getEnv(k, fb string) string {
	if v, ok := os.LookupEnv(k); ok && v != "" {
		return v
	}
	return fb
}
