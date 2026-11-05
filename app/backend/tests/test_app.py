from unittest.mock import Mock

import pytest

from app import create_app
from weather import CityNotFound, UpstreamError, UpstreamTimeout

WEATHER = {"city": "Haifa", "country": "Israel", "temperature_c": 22.6}


@pytest.fixture
def weather_client():
    return Mock()


@pytest.fixture
def http(weather_client):
    return create_app(client=weather_client).test_client()


def test_healthz_does_not_call_upstream(http, weather_client):
    resp = http.get("/healthz")

    assert resp.status_code == 200
    assert resp.json == {"status": "ok"}
    weather_client.get_weather.assert_not_called()


def test_weather_success(http, weather_client):
    weather_client.get_weather.return_value = WEATHER

    resp = http.get("/api/weather", query_string={"city": "  Haifa  "})

    assert resp.status_code == 200
    assert resp.json == WEATHER
    weather_client.get_weather.assert_called_once_with("Haifa")  # input is trimmed


@pytest.mark.parametrize("city", ["Tel Aviv", "São Paulo", "Ra'anana", "תל אביב"])
def test_accepts_real_city_names(http, weather_client, city):
    weather_client.get_weather.return_value = WEATHER

    assert http.get("/api/weather", query_string={"city": city}).status_code == 200


@pytest.mark.parametrize(
    "query",
    [{}, {"city": ""}, {"city": "   "}, {"city": "x" * 101}, {"city": "Haifa\x00"}],
    ids=["missing", "empty", "blank", "too-long", "control-char"],
)
def test_invalid_input_returns_400(http, weather_client, query):
    resp = http.get("/api/weather", query_string=query)

    assert resp.status_code == 400
    assert "error" in resp.json
    weather_client.get_weather.assert_not_called()


@pytest.mark.parametrize(
    ("exception", "status"),
    [
        (CityNotFound("Atlantis"), 404),
        (UpstreamTimeout("slow"), 504),
        (UpstreamError("boom"), 502),
    ],
)
def test_upstream_failures_map_to_status_codes(http, weather_client, exception, status):
    weather_client.get_weather.side_effect = exception

    resp = http.get("/api/weather", query_string={"city": "Atlantis"})

    assert resp.status_code == status
    assert set(resp.json) == {"error"}


def test_upstream_details_are_not_leaked(http, weather_client):
    weather_client.get_weather.side_effect = UpstreamError("internal URL https://secret.local")

    resp = http.get("/api/weather", query_string={"city": "Haifa"})

    assert "secret" not in resp.get_data(as_text=True)


def test_unknown_route_returns_json_404(http):
    resp = http.get("/nope")

    assert resp.status_code == 404
    assert "error" in resp.json
