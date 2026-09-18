create schema if not exists gold;

create table if not exists gold.DimUsuario (
    SkUsuario bigint generated always as identity primary key,

    IdUsuarioOrigem bigint not null unique,

    NomeUsuario text not null
        check (btrim(NomeUsuario) <> ''),

    -- Tier mais recente conhecido.
    Tier smallint not null
        check (Tier IN (1, 2, 3))
);

create table if not exists gold.FatoUsuarioSnapshot (
    -- Mantém a identificação da observação recebida da silver.
    SkObservacao bigint PRIMARY KEY
        REFERENCES silver.UsuarioSnapshot(SkObservacao),

    SkUsuario bigint not null
        REFERENCES gold.DimUsuario(SkUsuario),

    CargaBronze UUID not null
        REFERENCES bronze.CargaUsuario(CargaBronze),

    -- Valores históricos desta observação.
    Tier smallint not null
        check (Tier IN (1, 2, 3)),

    RendaMensalAnterior numeric(14, 2)
        check (
            RendaMensalAnterior >= 0
            and RendaMensalAnterior < 'Infinity'::numeric
        ),

    RendaMensalNova numeric(14, 2)
        check (
            RendaMensalNova >= 0
            and RendaMensalNova < 'Infinity'::numeric
        ),

    RegraRenda text
        check (
            RegraRenda in (
                'AUMENTO_200_POR_CENTO',
                'REDUCAO_10_POR_CENTO',
                'SEM_ALTERACAO'
            )
        ),

    DataAtualizacaoOrigem timestamp without time zone not null,
    DataIngestao timestamp without time zone not null,

    constraint FatoUsuarioSnapshotCargaUnica
        unique (SkUsuario, CargaBronze)
);

-- Compatibilidade com a fato criada antes das novas regras de renda.
ALTER TABLE gold.FatoUsuarioSnapshot
    ADD COLUMN IF NOT EXISTS RendaMensalAnterior numeric(14, 2)
        CHECK (
            RendaMensalAnterior >= 0
            AND RendaMensalAnterior < 'Infinity'::numeric
        );

ALTER TABLE gold.FatoUsuarioSnapshot
    ADD COLUMN IF NOT EXISTS RendaMensalNova numeric(14, 2)
        CHECK (
            RendaMensalNova >= 0
            AND RendaMensalNova < 'Infinity'::numeric
        );

ALTER TABLE gold.FatoUsuarioSnapshot
    ADD COLUMN IF NOT EXISTS RegraRenda text
        CHECK (
            RegraRenda IN (
                'AUMENTO_200_POR_CENTO',
                'REDUCAO_10_POR_CENTO',
                'SEM_ALTERACAO'
            )
        );




select * from gold.DimUsuario;

BEGIN;

-- Seleciona o cadastro mais recente conhecido de cada usuário.
WITH UltimoCadastro AS (
    SELECT DISTINCT ON (s.IdUsuarioOrigem)
        s.IdUsuarioOrigem,
        s.NomeUsuario,
        s.Tier
    FROM silver.UsuarioSnapshot AS s
    JOIN bronze.CargaUsuario AS b
        ON b.CargaBronze = s.CargaBronze
    ORDER BY
        s.IdUsuarioOrigem,
        s.DataAtualizacaoOrigem DESC,
        b.DataIngestao DESC NULLS LAST,
        s.SkObservacao DESC
)
INSERT INTO gold.DimUsuario AS d (
    IdUsuarioOrigem,
    NomeUsuario,
    Tier
)
SELECT
    IdUsuarioOrigem,
    NomeUsuario,
    Tier
FROM UltimoCadastro
WHERE TRUE
ON CONFLICT (IdUsuarioOrigem)
DO UPDATE SET
    NomeUsuario = EXCLUDED.NomeUsuario,
    Tier = EXCLUDED.Tier
WHERE
    (d.NomeUsuario, d.Tier)
    IS DISTINCT FROM
    (EXCLUDED.NomeUsuario, EXCLUDED.Tier);

-- Carrega todas as observações ainda não presentes na gold.
INSERT INTO gold.FatoUsuarioSnapshot (
    SkObservacao,
    SkUsuario,
    CargaBronze,
    Tier,
    RendaMensalAnterior,
    RendaMensalNova,
    RegraRenda,
    DataAtualizacaoOrigem,
    DataIngestao
)
SELECT
    s.SkObservacao,
    d.SkUsuario,
    s.CargaBronze,
    s.Tier,
    s.RendaMensal,
    s.RendaMensalNova,
    s.RegraRenda,
    s.DataAtualizacaoOrigem,
    b.DataIngestao
FROM silver.UsuarioSnapshot AS s
JOIN gold.DimUsuario AS d
    ON d.IdUsuarioOrigem = s.IdUsuarioOrigem
JOIN bronze.CargaUsuario AS b
    ON b.CargaBronze = s.CargaBronze
WHERE TRUE
ON CONFLICT (SkObservacao)
DO UPDATE SET
    RendaMensalAnterior = EXCLUDED.RendaMensalAnterior,
    RendaMensalNova = EXCLUDED.RendaMensalNova,
    RegraRenda = EXCLUDED.RegraRenda;

COMMIT;



-- Uma observação por usuário: a mais recente conhecida.
CREATE OR REPLACE VIEW gold.UsuarioAtual AS
SELECT DISTINCT ON (f.SkUsuario)
    f.SkUsuario,
    d.IdUsuarioOrigem,
    d.NomeUsuario,
    f.SkObservacao,
    f.CargaBronze,
    f.Tier,
    -- Mantém a coluna legada RendaMensal como a renda vigente.
    f.RendaMensalNova AS RendaMensal,
    f.DataAtualizacaoOrigem,
    f.DataIngestao,
    f.RendaMensalAnterior,
    f.RendaMensalNova,
    f.RegraRenda
FROM gold.FatoUsuarioSnapshot AS f
JOIN gold.DimUsuario AS d
    ON d.SkUsuario = f.SkUsuario
ORDER BY
    f.SkUsuario,
    f.DataAtualizacaoOrigem DESC,
    f.DataIngestao DESC,
    f.SkObservacao DESC;

-- Indicadores calculados sobre usuários, não sobre todas as cargas.
CREATE OR REPLACE VIEW gold.ResumoTierAtual AS
SELECT
    Tier,
    COUNT(*) AS QuantidadeUsuarios,

    ROUND(
        100.0 * COUNT(*) / SUM(COUNT(*)) OVER (),
        2
    ) AS PercentualUsuarios,

    COUNT(RendaMensalNova) AS UsuariosComRendaInformada,

    ROUND(AVG(RendaMensalNova), 2) AS RendaMedia
FROM gold.UsuarioAtual
GROUP BY Tier;

-- Consulta de auditoria: compara a renda recebida com a renda transformada.
CREATE OR REPLACE VIEW gold.ComparativoRendaAtual AS
SELECT
    SkUsuario,
    IdUsuarioOrigem,
    NomeUsuario,
    RendaMensalAnterior,
    RendaMensalNova,
    RendaMensalNova - RendaMensalAnterior AS DiferencaRenda,
    CASE
        WHEN RendaMensalAnterior IS NULL OR RendaMensalAnterior = 0 THEN NULL
        ELSE ROUND(
            100.0 * (RendaMensalNova - RendaMensalAnterior)
            / RendaMensalAnterior,
            2
        )
    END AS PercentualVariacao,
    RegraRenda,
    DataAtualizacaoOrigem,
    DataIngestao
FROM gold.UsuarioAtual;



SELECT
    (SELECT COUNT(*) FROM gold.DimUsuario) AS Usuarios,
    (SELECT COUNT(*) FROM gold.FatoUsuarioSnapshot) AS Observacoes,
    (SELECT COUNT(*) FROM gold.UsuarioAtual) AS UsuariosAtuais;

SELECT *
FROM gold.ResumoTierAtual
ORDER BY Tier;

SELECT *
FROM gold.ComparativoRendaAtual
ORDER BY IdUsuarioOrigem;



VACUUM (ANALYZE) gold.DimUsuario;
VACUUM (ANALYZE) gold.FatoUsuarioSnapshot;



SELECT *
FROM gold.UsuarioAtual
ORDER BY IdUsuarioOrigem;

SELECT *
FROM gold.ResumoTierAtual
ORDER BY Tier;

SELECT *
FROM gold.ComparativoRendaAtual
ORDER BY IdUsuarioOrigem;