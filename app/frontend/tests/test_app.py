from unittest.mock import Mock, patch

import pytest
import requests

from app import create_app

WEATHER = {
    "city": "Haifa",
    "country": "Israel",
    "temperature_c": 22.6,
    "apparent_temperature_c": 22.7,
    "humidity_pct": 69,
    "wind_speed_kmh": 14.9,
    "condition": "Partly cloudy",
    "observed_at": "2026-11-05T14:30",
    "timezone": "Asia/Jerusalem",
}


def backend_response(status, body):
    resp = Mock(status_code=status)
    resp.json.return_value = body
    return resp


@pytest.fixture
def backend_get():
    with patch("requests.Session.get") as get:
        yield get


@pytest.fixture
def http(monkeypatch):
    monkeypatch.setenv("BACKEND_URL", "http://backend.test:8000/")
    monkeypatch.setenv("BACKEND_TIMEOUT", "7")
    return create_app().test_client()


def test_healthz_does_not_call_backend(http, backend_get):
    assert http.get("/healthz").status_code == 200
    backend_get.assert_not_called()


def test_form_renders_without_calling_backend(http, backend_get):
    resp = http.get("/")

    assert resp.status_code == 200
    assert b'name="city"' in resp.data
    backend_get.assert_not_called()


def test_shows_weather(http, backend_get):
    backend_get.return_value = backend_response(200, WEATHER)

    resp = http.get("/", query_string={"city": " Haifa "})

    assert resp.status_code == 200
    assert "Haifa, Israel" in resp.get_data(as_text=True)
    assert "Partly cloudy" in resp.get_data(as_text=True)


def test_calls_configured_backend_with_timeout(http, backend_get):
    backend_get.return_value = backend_response(200, WEATHER)

    http.get("/", query_string={"city": "Haifa"})

    backend_get.assert_called_once_with(
        "http://backend.test:8000/api/weather", params={"city": "Haifa"}, timeout=7.0
    )


def test_shows_backend_not_found_message(http, backend_get):
    backend_get.return_value = backend_response(404, {"error": "city 'Atlantis' not found"})

    resp = http.get("/", query_string={"city": "Atlantis"})

    assert resp.status_code == 404
    assert "city &#39;Atlantis&#39; not found" in resp.get_data(as_text=True)


@pytest.mark.parametrize("status", [500, 502, 504])
def test_backend_server_errors_show_generic_message(http, backend_get, status):
    backend_get.return_value = backend_response(status, {"error": "internal detail"})

    resp = http.get("/", query_string={"city": "Haifa"})

    assert resp.status_code == 502
    assert "unavailable" in resp.get_data(as_text=True)
    assert "internal detail" not in resp.get_data(as_text=True)


@pytest.mark.parametrize(
    ("exception", "status", "text"),
    [
        (requests.ConnectionError("refused"), 502, "unavailable"),
        (requests.Timeout("slow"), 504, "too long"),
    ],
)
def test_backend_unreachable(http, backend_get, exception, status, text):
    backend_get.side_effect = exception

    resp = http.get("/", query_string={"city": "Haifa"})

    assert resp.status_code == status
    assert text in resp.get_data(as_text=True)


def test_non_json_backend_response(http, backend_get):
    resp_mock = backend_response(502, None)
    resp_mock.json.side_effect = ValueError("HTML error page from a proxy")
    backend_get.return_value = resp_mock

    assert http.get("/", query_string={"city": "Haifa"}).status_code == 502


def test_city_is_html_escaped(http, backend_get):
    backend_get.return_value = backend_response(404, {"error": "not found"})

    resp = http.get("/", query_string={"city": "<script>alert(1)</script>"})

    assert "<script>alert(1)</script>" not in resp.get_data(as_text=True)
    assert "&lt;script&gt;" in resp.get_data(as_text=True)
