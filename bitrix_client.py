import os
import requests
from urllib.parse import urljoin
from dotenv import load_dotenv

load_dotenv()


class BitrixClient:
    """Клиент для подключения к сайту на 1С-Битрикс через админку и REST API."""

    def __init__(self, base_url: str, login: str, password: str):
        self.base_url = base_url.rstrip("/")
        self.login = login
        self.password = password
        self.session = requests.Session()
        self.session.headers.update({
            "User-Agent": "Mozilla/5.0 (compatible; BitrixClient/1.0)"
        })
        # Отключить системный прокси для прямого подключения
        self.session.trust_env = False
        self._authenticated = False

    # ------------------------------------------------------------------
    # Аутентификация через форму администратора
    # ------------------------------------------------------------------

    def authenticate(self) -> bool:
        """Войти в административный раздел Битрикс."""
        login_url = urljoin(self.base_url, "/bitrix/admin/index.php")

        # Первый запрос — получить форму и CSRF-токен
        resp = self.session.get(login_url, timeout=15)
        resp.raise_for_status()

        payload = {
            "AUTH_FORM": "Y",
            "TYPE": "AUTH",
            "backurl": "/bitrix/admin/",
            "USER_LOGIN": self.login,
            "USER_PASSWORD": self.password,
            "USER_REMEMBER": "N",
        }

        resp = self.session.post(login_url, data=payload, timeout=15)
        resp.raise_for_status()

        # Проверяем, что вошли (в заголовке будет redirect или страница без формы входа)
        if "USER_LOGIN" in resp.text and "USER_PASSWORD" in resp.text:
            raise RuntimeError("Аутентификация не удалась. Проверьте логин/пароль.")

        self._authenticated = True
        print(f"[OK] Успешно вошли в админку: {self.base_url}/bitrix/admin/")
        return True

    # ------------------------------------------------------------------
    # REST API
    # ------------------------------------------------------------------

    def rest_call(self, method: str, params: dict | None = None) -> dict:
        """
        Вызов метода Битрикс REST API.

        Требует, чтобы в системе был создан входящий вебхук
        или была выполнена аутентификация через OAuth.
        Используется сессионный auth после вызова authenticate().
        """
        if params is None:
            params = {}

        url = urljoin(self.base_url, f"/rest/{method}.json")
        resp = self.session.post(url, json=params, timeout=15)
        resp.raise_for_status()
        data = resp.json()

        if "error" in data:
            raise RuntimeError(f"REST API error: {data['error']} — {data.get('error_description', '')}")

        return data.get("result", data)

    # ------------------------------------------------------------------
    # Удобные методы
    # ------------------------------------------------------------------

    def get_site_info(self) -> dict:
        """Получить базовую информацию о сайте."""
        return self.rest_call("app.info")

    def get_iblock_list(self) -> list:
        """Список инфоблоков."""
        return self.rest_call("lists.iblock.get")

    def get_users(self, filter: dict | None = None) -> list:
        """Получить список пользователей."""
        params = {}
        if filter:
            params["filter"] = filter
        return self.rest_call("user.get", params)

    def admin_get(self, path: str, **kwargs) -> requests.Response:
        """Прямой GET-запрос в административный раздел с активной сессией."""
        if not self._authenticated:
            self.authenticate()
        url = urljoin(self.base_url, path)
        return self.session.get(url, timeout=15, **kwargs)

    def admin_post(self, path: str, data: dict, **kwargs) -> requests.Response:
        """Прямой POST-запрос в административный раздел с активной сессией."""
        if not self._authenticated:
            self.authenticate()
        url = urljoin(self.base_url, path)
        return self.session.post(url, data=data, timeout=15, **kwargs)


# ------------------------------------------------------------------
# Фабричная функция — читает настройки из .env
# ------------------------------------------------------------------

def create_client_from_env() -> BitrixClient:
    url = os.environ["BITRIX_URL"]
    login = os.environ["BITRIX_ADMIN_LOGIN"]
    password = os.environ["BITRIX_ADMIN_PASSWORD"]
    return BitrixClient(url, login, password)
