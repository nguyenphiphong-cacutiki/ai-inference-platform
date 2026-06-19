"""Configuration, read from environment variables (12-factor style)."""

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    # All values can be overridden via environment variables of the same name.
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    # --- Milvus (vector database) ---
    milvus_host: str = "milvus"
    milvus_port: int = 19530
    collection_name: str = "documents"

    # --- Ollama (embedding provider) ---
    # We reuse the same Ollama server that serves the LLM. nomic-embed-text
    # produces 768-dimensional vectors, so embed_dim MUST be 768 to match.
    ollama_url: str = "http://ollama:11434"
    embed_model: str = "nomic-embed-text"
    embed_dim: int = 768

    # --- Search defaults ---
    default_top_k: int = 5


settings = Settings()
