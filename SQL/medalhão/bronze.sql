create schema if not exists medalhao;

CREATE TABLE IF NOT EXISTS medalhao.Bronze (
    CargaBronze STRING PRIMARY KEY,
    NomeArquivo STRING NOT NULL,
    HashArquivo STRING NOT NULL,
    DataIngestao TIMESTAMP NOT NULL
        DEFAULT CURRENT_TIMESTAMP,
    DadoBruto VARIANT NOT NULL
)
TBLPROPERTIES ('delta.feature.allowColumnDefaults' = 'supported');