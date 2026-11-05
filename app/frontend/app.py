"""SkyWatch frontend: a city search page that shows weather from the backend API."""

import os

import requests
from flask import Flask, render_template, request

UNAVAILABLE = "The weather service is unavailable right now. Please try again later."


def create_app():
    app = Flask(__name__)
    backend_url = os.environ.get("BACKEND_URL", "http://localhost:8000").rstrip("/")
    timeout = float(os.environ.get("BACKEND_TIMEOUT", "15"))
    session = requests.Session()

    def fetch_weather(city):
        """Return (weather, error_message, http_status) for the page."""
        try:
            resp = session.get(f"{backend_url}/api/weather", params={"city": city}, timeout=timeout)
        except requests.Timeout:
            app.logger.warning("backend timeout for city=%r", city)
            return None, "The weather service took too long to respond.", 504
        except requests.RequestException as exc:
            app.logger.warning("backend unreachable: %s", exc)
            return None, UNAVAILABLE, 502

        try:
            body = resp.json()
        except ValueError:
            app.logger.warning("backend returned non-JSON, status=%s", resp.status_code)
            return None, UNAVAILABLE, 502

        if resp.status_code == 200:
            return body, None, 200
        if resp.status_code in (400, 404):
            # Client errors carry a message meant for the user ("city 'x' not found").
            return None, body.get("error", "Invalid request."), resp.status_code
        return None, UNAVAILABLE, 502

    @app.get("/healthz")
    def healthz():
        # Process health only; no backend call, so a backend outage does not
        # restart or unroute the frontend (it keeps serving a clear error page).
        return {"status": "ok"}

    @app.get("/")
    def index():
        city = request.args.get("city", "").strip()
        if not city:
            return render_template("index.html")
        weather, error, status = fetch_weather(city)
        return render_template("index.html", city=city, weather=weather, error=error), status

    return app
