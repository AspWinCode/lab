"""
Пример подключения к сайту на 1С-Битрикс и вызова REST API.
Запуск: python main.py
"""

from bitrix_client import create_client_from_env


def main():
    client = create_client_from_env()

    # 1. Войти в административный раздел
    client.authenticate()

    # 2. Попробовать вызов REST API
    print("\n--- REST API: app.info ---")
    try:
        info = client.get_site_info()
        print(info)
    except Exception as e:
        print(f"REST API недоступен или не настроен: {e}")

    # 3. Получить список пользователей
    print("\n--- REST API: user.get ---")
    try:
        users = client.get_users()
        for u in users[:5]:
            print(f"  {u.get('ID')} | {u.get('LOGIN')} | {u.get('EMAIL')}")
    except Exception as e:
        print(f"Не удалось получить пользователей: {e}")

    # 4. Прямой запрос к странице статистики в админке
    print("\n--- Прямой запрос: /bitrix/admin/stat_host_list.php ---")
    resp = client.admin_get("/bitrix/admin/stat_host_list.php")
    if resp.ok:
        print(f"Статус: {resp.status_code}, размер страницы: {len(resp.text)} байт")
    else:
        print(f"Ошибка: {resp.status_code}")


if __name__ == "__main__":
    main()
