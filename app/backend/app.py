"""SkyWatch backend: an HTTP API that returns the current weather for a city."""

import os

from flask import Flask, request
from werkzeug.exceptions import HTTPException

from weather import CityNotFound, OpenMeteoClient, UpstreamError, UpstreamTimeout

MAX_CITY_LENGTH = 100


def parse_city(raw):
    """Return a cleaned city name, or raise ValueError with a client-facing message."""
    city = (raw or "").strip()
    if not city:
        raise ValueError("query parameter 'city' is required")
    if len(city) > MAX_CITY_LENGTH:
        raise ValueError(f"city must be at most {MAX_CITY_LENGTH} characters")
    if not city.isprintable():
        raise ValueError("city contains invalid characters")
    return city


def error(status, message):
    return {"error": message}, status


def create_app(client=None):
    app = Flask(__name__)

    if client is None:
        client = OpenMeteoClient(
            geocoding_url=os.environ.get(
                "GEOCODING_URL", "https://geocoding-api.open-meteo.com/v1/search"
            ),
            forecast_url=os.environ.get("FORECAST_URL", "https://api.open-meteo.com/v1/forecast"),
            timeout=(
                float(os.environ.get("UPSTREAM_CONNECT_TIMEOUT", "2")),
                float(os.environ.get("UPSTREAM_READ_TIMEOUT", "4")),
            ),
        )

    @app.get("/healthz")
    def healthz():
        # Liveness/readiness of this process only. Deliberately no Open-Meteo call:
        # an external outage must not make Kubernetes restart or unroute healthy pods.
        return {"status": "ok"}

    @app.get("/api/weather")
    def weather():
        try:
            city = parse_city(request.args.get("city"))
        except ValueError as exc:
            return error(400, str(exc))

        try:
            return client.get_weather(city)
        except CityNotFound:
            return error(404, f"city '{city}' not found")
        except UpstreamTimeout as exc:
            app.logger.warning("upstream timeout for city=%r: %s", city, exc)
            return error(504, "weather service timed out")
        except UpstreamError as exc:
            app.logger.warning("upstream error for city=%r: %s", city, exc)
            return error(502, "weather service unavailable")

    @app.errorhandler(HTTPException)
    def http_error(exc):
        # Keep unknown routes / wrong methods in the same JSON shape as other errors.
        return error(exc.code, exc.description)

    return app
