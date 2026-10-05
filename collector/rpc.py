"""קריאות RPC לסכמת api בסופרבייס (מפתח service_role בלבד)."""
import requests


class Rpc:
    def __init__(self, url, service_key, session=None):
        self.base = url.rstrip("/") + "/rest/v1/rpc/"
        self.session = session or requests.Session()
        self.headers = {"apikey": service_key, "Authorization": f"Bearer {service_key}",
                        "Content-Type": "application/json", "Content-Profile": "api", "Accept-Profile": "api"}

    def call(self, function, payload):
        response = self.session.post(self.base + function, json=payload, headers=self.headers, timeout=120)
        if response.status_code >= 400:
            raise RuntimeError(f"{function}: HTTP {response.status_code} {response.text[:500]}")
        return response.json() if response.text else None
