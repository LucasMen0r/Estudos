CREATE SCHEMA IF NOT EXISTS bronze;

CREATE TABLE IF NOT EXISTS bronze.CargaUsuario (
    CargaBronze UUID PRIMARY KEY,
    NomeArquivo text NOT NULL,
    HashArquivo text NOT NULL,
    DataIngestao timestamp without time zone NOT NULL
        DEFAULT CURRENT_TIMESTAMP,
    DadoBruto jsonb NOT NULL,

    CONSTRAINT CargaUsuarioLista
        CHECK (jsonb_typeof(DadoBruto) = 'array')
);

-- Necessário para o ON CONFLICT (HashArquivo) usado na ingestão.
CREATE UNIQUE INDEX IF NOT EXISTS UX_CargaUsuario_HashArquivo
    ON bronze.CargaUsuario(HashArquivo);
    



select * from bronze.CargaUsuario;