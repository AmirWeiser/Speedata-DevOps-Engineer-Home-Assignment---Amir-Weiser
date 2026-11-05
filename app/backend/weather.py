"""Open-Meteo client: geocode a city name, then fetch its current weather."""

import requests

CURRENT_FIELDS = (
    "temperature_2m,apparent_temperature,relative_humidity_2m,wind_speed_10m,weather_code,is_day"
)

# WMO weather interpretation codes, as documented by Open-Meteo.
WMO_CODES = {
    0: "Clear sky",
    1: "Mainly clear",
    2: "Partly cloudy",
    3: "Overcast",
    45: "Fog",
    48: "Depositing rime fog",
    51: "Light drizzle",
    53: "Moderate drizzle",
    55: "Dense drizzle",
    56: "Light freezing drizzle",
    57: "Dense freezing drizzle",
    61: "Slight rain",
    63: "Moderate rain",
    65: "Heavy rain",
    66: "Light freezing rain",
    67: "Heavy freezing rain",
    71: "Slight snowfall",
    73: "Moderate snowfall",
    75: "Heavy snowfall",
    77: "Snow grains",
    80: "Slight rain showers",
    81: "Moderate rain showers",
    82: "Violent rain showers",
    85: "Slight snow showers",
    86: "Heavy snow showers",
    95: "Thunderstorm",
    96: "Thunderstorm with slight hail",
    99: "Thunderstorm with heavy hail",
}


class CityNotFound(Exception):
    """The geocoding API returned no match for the city."""


class UpstreamTimeout(Exception):
    """Open-Meteo did not respond within the configured timeout."""


class UpstreamError(Exception):
    """Open-Meteo was unreachable or returned an error or an unexpected payload."""


class OpenMeteoClient:
    def __init__(self, geocoding_url, forecast_url, timeout):
        self.geocoding_url = geocoding_url
        self.forecast_url = forecast_url
        self.timeout = timeout  # (connect, read) seconds, applied to every call
        self.session = requests.Session()  # reuses TCP/TLS connections across requests

    def get_weather(self, city):
        place = self._geocode(city)
        data = self._get_json(
            self.forecast_url,
            {
                "latitude": place["latitude"],
                "longitude": place["longitude"],
                "current": CURRENT_FIELDS,
                "timezone": "auto",
            },
        )
        try:
            current = data["current"]
            return {
                "city": place["name"],
                "country": place.get("country", ""),
                "latitude": place["latitude"],
                "longitude": place["longitude"],
                "temperature_c": current["temperature_2m"],
                "apparent_temperature_c": current["apparent_temperature"],
                "humidity_pct": current["relative_humidity_2m"],
                "wind_speed_kmh": current["wind_speed_10m"],
                "condition": WMO_CODES.get(current["weather_code"], "Unknown"),
                "is_day": bool(current["is_day"]),
                "observed_at": current["time"],
                "timezone": data.get("timezone", ""),
            }
        except (KeyError, TypeError) as exc:
            raise UpstreamError(f"unexpected forecast payload: {exc!r}") from exc

    def _geocode(self, city):
        data = self._get_json(
            self.geocoding_url, {"name": city, "count": 1, "language": "en", "format": "json"}
        )
        # Open-Meteo answers an unknown city with HTTP 200 and no "results" key.
        results = data.get("results") if isinstance(data, dict) else None
        if not results:
            raise CityNotFound(city)
        place = results[0]
        if not all(key in place for key in ("name", "latitude", "longitude")):
            raise UpstreamError(f"unexpected geocoding payload: {place!r}")
        return place

    def _get_json(self, url, params):
        try:
            response = self.session.get(url, params=params, timeout=self.timeout)
            response.raise_for_status()
            return response.json()
        except requests.Timeout as exc:
            raise UpstreamTimeout(f"timed out calling {url}") from exc
        except (requests.RequestException, ValueError) as exc:
            # ValueError covers a body that is not valid JSON.
            raise UpstreamError(f"failed calling {url}: {exc}") from exc
