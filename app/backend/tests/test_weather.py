from unittest.mock import Mock

import pytest
import requests

from weather import CityNotFound, OpenMeteoClient, UpstreamError, UpstreamTimeout

# Payload shapes captured from the real Open-Meteo APIs.
GEOCODE_HAIFA = {
    "results": [{"name": "Haifa", "country": "Israel", "latitude": 32.81303, "longitude": 34.99928}]
}
FORECAST = {
    "timezone": "Asia/Jerusalem",
    "current": {
        "time": "2026-11-05T14:30",
        "temperature_2m": 22.6,
        "apparent_temperature": 22.7,
        "relative_humidity_2m": 69,
        "wind_speed_10m": 14.9,
        "weather_code": 2,
        "is_day": 1,
    },
}


def response(payload, status=200):
    resp = Mock(status_code=status)
    resp.json.return_value = payload
    if status >= 400:
        resp.raise_for_status.side_effect = requests.HTTPError(f"{status} error")
    return resp


@pytest.fixture
def client():
    c = OpenMeteoClient("https://geo.test", "https://forecast.test", timeout=(2, 4))
    c.session = Mock()
    return c


def test_returns_current_weather(client):
    client.session.get.side_effect = [response(GEOCODE_HAIFA), response(FORECAST)]

    result = client.get_weather("Haifa")

    assert result["city"] == "Haifa"
    assert result["country"] == "Israel"
    assert result["temperature_c"] == 22.6
    assert result["condition"] == "Partly cloudy"
    assert result["is_day"] is True
    assert result["timezone"] == "Asia/Jerusalem"


def test_passes_coordinates_and_timeout_to_forecast(client):
    client.session.get.side_effect = [response(GEOCODE_HAIFA), response(FORECAST)]

    client.get_weather("Haifa")

    url, kwargs = client.session.get.call_args.args[0], client.session.get.call_args.kwargs
    assert url == "https://forecast.test"
    assert kwargs["params"]["latitude"] == 32.81303
    assert kwargs["timeout"] == (2, 4)


def test_unknown_weather_code_is_reported_as_unknown(client):
    forecast = {**FORECAST, "current": {**FORECAST["current"], "weather_code": 1234}}
    client.session.get.side_effect = [response(GEOCODE_HAIFA), response(forecast)]

    assert client.get_weather("Haifa")["condition"] == "Unknown"


def test_city_not_found_when_no_results_key(client):
    # Real behaviour: HTTP 200 with only "generationtime_ms".
    client.session.get.return_value = response({"generationtime_ms": 0.08})

    with pytest.raises(CityNotFound):
        client.get_weather("xqzvbnm")


def test_timeout_raises_upstream_timeout(client):
    client.session.get.side_effect = requests.ReadTimeout("read timed out")

    with pytest.raises(UpstreamTimeout):
        client.get_weather("Haifa")


def test_connection_error_raises_upstream_error(client):
    client.session.get.side_effect = requests.ConnectionError("DNS failure")

    with pytest.raises(UpstreamError):
        client.get_weather("Haifa")


def test_http_error_raises_upstream_error(client):
    client.session.get.side_effect = [response(GEOCODE_HAIFA), response({}, status=500)]

    with pytest.raises(UpstreamError):
        client.get_weather("Haifa")


def test_invalid_json_raises_upstream_error(client):
    bad = response(None)
    bad.json.side_effect = ValueError("not JSON")
    client.session.get.return_value = bad

    with pytest.raises(UpstreamError):
        client.get_weather("Haifa")


def test_malformed_forecast_raises_upstream_error(client):
    client.session.get.side_effect = [response(GEOCODE_HAIFA), response({"timezone": "UTC"})]

    with pytest.raises(UpstreamError):
        client.get_weather("Haifa")
