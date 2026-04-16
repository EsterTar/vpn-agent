from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    agent_token: str
    xray_config_path: str = "/usr/local/etc/xray/config.json"
    xray_service: str = "xray"
    xray_api_address: str = "127.0.0.1:10085"

    model_config = {"env_file": "server-agent.env"}


settings = Settings()
