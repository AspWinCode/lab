"""
Исследование файловой структуры сайта на 1С-Битрикс через файловый менеджер админки.
Запуск: python explore_files.py
"""

import re
import json
import urllib.parse
from pathlib import Path
from bitrix_client import create_client_from_env


# Директории, которые Битрикс использует сам — трогать нельзя
BITRIX_CORE_DIRS = {
    "/bitrix/modules",
    "/bitrix/components",
    "/bitrix/templates",
    "/bitrix/gadgets",
    "/bitrix/wizards",
    "/bitrix/php_interface",
    "/bitrix/js",
    "/bitrix/images",
    "/bitrix/tools",
    "/bitrix/admin",
}

# Директории с кешем/временными файлами — безопасно удалять
SAFE_TO_DELETE_DIRS = {
    "/bitrix/cache",
    "/bitrix/managed_cache",
    "/bitrix/stack_cache",
    "/bitrix/html_pages",
    "/.logs",
    "/upload/tmp",
}

# Паттерны файлов, которые обычно можно удалить
DELETABLE_PATTERNS = [
    r"\.bak$",
    r"\.old$",
    r"\.orig$",
    r"\.log$",
    r"_backup",
    r"backup_",
    r"\.sql\.gz$",
    r"\.sql$",
    r"phpinfo\.php$",
    r"test\.php$",
    r"info\.php$",
]


class BitrixFileExplorer:
    def __init__(self, client):
        self.client = client

    def list_dir(self, path: str = "/") -> dict:
        """Получить листинг директории через файловый менеджер Битрикс."""
        params = {
            "action": "list",
            "path": path,
            "site_id": "s1",
        }
        resp = self.client.admin_get(
            "/bitrix/admin/fileman_file_list.php",
            params=params
        )
        return self._parse_file_list(resp.text, path)

    def list_dir_json(self, path: str = "/") -> list:
        """Попытка получить JSON-листинг через fileman API."""
        params = {
            "action": "list",
            "dir": path,
            "site_id": "s1",
            "sessid": "",
        }
        resp = self.client.admin_post(
            "/bitrix/admin/fileman_list.php",
            data=params
        )
        try:
            data = resp.json()
            return data.get("files", [])
        except Exception:
            return []

    def _parse_file_list(self, html: str, current_path: str) -> dict:
        """Парсим HTML страницу файлового менеджера."""
        result = {"path": current_path, "dirs": [], "files": []}

        # Ищем ссылки на директории
        dir_pattern = re.compile(
            r'fileman_file_list\.php\?[^"]*path=([^&"]+)[^"]*"[^>]*>([^<]+)</a',
            re.IGNORECASE
        )
        for m in dir_pattern.finditer(html):
            p = urllib.parse.unquote(m.group(1))
            name = m.group(2).strip()
            if p != current_path and name not in ("..", "."):
                result["dirs"].append({"name": name, "path": p})

        # Ищем файлы
        file_pattern = re.compile(
            r'fileman_file_edit\.php\?[^"]*path=([^&"]+)[^"]*"[^>]*>([^<]+)</a',
            re.IGNORECASE
        )
        for m in file_pattern.finditer(html):
            p = urllib.parse.unquote(m.group(1))
            name = m.group(2).strip()
            result["files"].append({"name": name, "path": p})

        return result

    def explore_root(self) -> dict:
        """Получить корневую структуру сайта."""
        # Запрашиваем страницу файлового менеджера
        resp = self.client.admin_get("/bitrix/admin/fileman_index.php")
        html = resp.text

        # Ищем список корневых директорий/файлов из iframe или таблицы
        dirs = []
        files = []

        # Паттерн для директорий в файловом менеджере Битрикс
        for m in re.finditer(
            r'<td[^>]*class="[^"]*folder[^"]*"[^>]*>.*?href="[^"]*path=([^"&]+)',
            html, re.IGNORECASE | re.DOTALL
        ):
            dirs.append(urllib.parse.unquote(m.group(1)))

        return {"html_length": len(html), "dirs": dirs, "files": files, "raw_preview": html[:3000]}

    def smart_list(self, path: str = "/") -> list:
        """
        Универсальный листинг — пробует несколько endpoint'ов Битрикс.
        Возвращает список объектов {name, path, type, size}.
        """
        # Вариант 1: fileman через GET-параметры
        resp = self.client.admin_get(
            "/bitrix/admin/fileman_index.php",
            params={"path": path, "site_id": "s1"}
        )

        items = []
        html = resp.text

        # Извлекаем строки таблицы файлового менеджера
        row_pattern = re.compile(
            r'<tr[^>]*>\s*<td[^>]*>(.*?)</tr>',
            re.IGNORECASE | re.DOTALL
        )
        link_pattern = re.compile(r'href="([^"]+)"[^>]*>([^<]+)<', re.IGNORECASE)
        size_pattern = re.compile(r'(\d[\d\s]*(?:KB|MB|GB|байт|bytes))', re.IGNORECASE)

        for row in row_pattern.finditer(html):
            row_text = row.group(1)
            link_m = link_pattern.search(row_text)
            if not link_m:
                continue
            href = link_m.group(1)
            name = link_m.group(2).strip()
            size_m = size_pattern.search(row_text)
            size = size_m.group(1) if size_m else ""

            if "fileman_file_list" in href or "path=" in href:
                # Это директория
                path_m = re.search(r'path=([^&"]+)', href)
                if path_m:
                    items.append({
                        "name": name,
                        "path": urllib.parse.unquote(path_m.group(1)),
                        "type": "dir",
                        "size": "",
                    })
            elif "fileman_file_edit" in href or "file=" in href:
                # Это файл
                items.append({
                    "name": name,
                    "path": href,
                    "type": "file",
                    "size": size,
                })

        return items, html


def classify_path(path: str) -> str:
    """Классифицировать путь — можно ли удалить."""
    p = path.lower()
    for d in SAFE_TO_DELETE_DIRS:
        if p.startswith(d):
            return "SAFE_DELETE"
    for d in BITRIX_CORE_DIRS:
        if p.startswith(d):
            return "KEEP_CORE"
    for pat in DELETABLE_PATTERNS:
        if re.search(pat, p):
            return "LIKELY_DELETE"
    return "REVIEW"


def main():
    client = create_client_from_env()
    client.authenticate()

    explorer = BitrixFileExplorer(client)

    print("\n" + "=" * 60)
    print("ИССЛЕДОВАНИЕ ФАЙЛОВОЙ СТРУКТУРЫ САЙТА")
    print("=" * 60)

    # Получаем корень
    items, raw_html = explorer.smart_list("/")

    print(f"\nКорневая директория '/' — найдено элементов: {len(items)}")
    print(f"Размер HTML страницы: {len(raw_html)} символов\n")

    if items:
        for item in items:
            tag = classify_path(item["path"])
            icon = "📁" if item["type"] == "dir" else "📄"
            print(f"  [{tag:12}] {icon} {item['name']:<30} {item['size']}")
    else:
        # Если парсинг не дал результата — сохраняем HTML для анализа
        html_path = Path("/home/user/lab/admin_fileman.html")
        html_path.write_text(raw_html, encoding="utf-8")
        print(f"Автоматический парсинг не дал результатов.")
        print(f"HTML сохранён в: {html_path}")
        print(f"Первые 2000 символов:\n")
        print(raw_html[:2000])

    # Сохраняем полный HTML для ручного анализа
    Path("/home/user/lab/admin_fileman.html").write_text(raw_html, encoding="utf-8")
    print(f"\n[INFO] Полный HTML файлового менеджера сохранён в admin_fileman.html")

    # Также пробуем получить несколько важных директорий
    key_dirs = ["/bitrix", "/upload", "/local", "/img", "/images", "/backup"]
    print("\n--- Проверка ключевых директорий ---")
    for d in key_dirs:
        try:
            items2, html2 = explorer.smart_list(d)
            exists = "найдено" if html2 and "404" not in html2[:200] else "нет"
            print(f"  {d:<20} — {exists}, элементов: {len(items2)}")
        except Exception as e:
            print(f"  {d:<20} — ошибка: {e}")


if __name__ == "__main__":
    main()
