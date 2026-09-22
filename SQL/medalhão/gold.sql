use schema medalhao;

create table if not exists gold.DimUsuario (
    SkUsuario bigint generated always as identity primary key,

    IdUsuarioOrigem bigint not null,

    NomeUsuario STRING not null
        check (btrim(NomeUsuario) <> ''),

    -- Tier mais recente conhecido.
    Tier smallint not null
        check (Tier IN (1, 2, 3))
);

create table if not exists gold.FatoUsuarioSnapshot (
    -- Mantém a identificação da observação recebida da silver.
    SkObservacao bigint PRIMARY KEY,

    SkUsuario bigint not null
        REFERENCES gold.DimUsuario(SkUsuario),

    CargaBronze STRING not null
        REFERENCES bronze.CargaUsuario(CargaBronze),

    -- Valores históricos desta observação.
    Tier smallint not null
        check (Tier IN (1, 2, 3)),

    RendaMensalAnterior DECIMAL(14, 2)
        check (RendaMensalAnterior >= 0),

    RendaMensalNova DECIMAL(14, 2)
        check (RendaMensalNova >= 0),

    RegraRenda STRING
        check (
            RegraRenda in (
                'AUMENTO_200_POR_CENTO',
                'REDUCAO_10_POR_CENTO',
                'SEM_ALTERACAO'
            )
        ),

    DataAtualizacaoOrigem TIMESTAMP not null,
    DataIngestao TIMESTAMP not null,

    FOREIGN KEY (SkObservacao) REFERENCES silver.UsuarioSnapshot(SkObservacao)
);

select * from gold.DimUsuario;

-- Seleciona o cadastro mais recente conhecido de cada usuário.
WITH UltimoCadastro AS (
    SELECT
        s.IdUsuarioOrigem,
        s.NomeUsuario,
        s.Tier,
        ROW_NUMBER() OVER (
            PARTITION BY s.IdUsuarioOrigem
            ORDER BY
                s.DataAtualizacaoOrigem DESC,
                b.DataIngestao DESC NULLS LAST,
                s.SkObservacao DESC
        ) AS rn
    FROM silver.UsuarioSnapshot AS s
    JOIN bronze.CargaUsuario AS b
        ON b.CargaBronze = s.CargaBronze
)
MERGE INTO gold.DimUsuario AS d
USING (SELECT IdUsuarioOrigem, NomeUsuario, Tier FROM UltimoCadastro WHERE rn = 1) AS u
ON d.IdUsuarioOrigem = u.IdUsuarioOrigem
WHEN MATCHED AND (
    d.NomeUsuario IS DISTINCT FROM u.NomeUsuario
    OR d.Tier IS DISTINCT FROM u.Tier
)
    THEN UPDATE SET
        NomeUsuario = u.NomeUsuario,
        Tier = u.Tier
WHEN NOT MATCHED
    THEN INSERT (IdUsuarioOrigem, NomeUsuario, Tier)
    VALUES (u.IdUsuarioOrigem, u.NomeUsuario, u.Tier);

-- Carrega todas as observações ainda não presentes na gold.
MERGE INTO gold.FatoUsuarioSnapshot AS f
USING (
    SELECT
        s.SkObservacao,
        d.SkUsuario,
        s.CargaBronze,
        s.Tier,
        s.RendaMensal AS RendaMensalAnterior,
        s.RendaMensalNova,
        s.RegraRenda,
        s.DataAtualizacaoOrigem,
        b.DataIngestao
    FROM silver.UsuarioSnapshot AS s
    JOIN gold.DimUsuario AS d
        ON d.IdUsuarioOrigem = s.IdUsuarioOrigem
    JOIN bronze.CargaUsuario AS b
        ON b.CargaBronze = s.CargaBronze
) AS src
ON f.SkObservacao = src.SkObservacao
WHEN MATCHED THEN UPDATE SET
    RendaMensalAnterior = src.RendaMensalAnterior,
    RendaMensalNova = src.RendaMensalNova,
    RegraRenda = src.RegraRenda
WHEN NOT MATCHED THEN INSERT (
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
VALUES (
    src.SkObservacao,
    src.SkUsuario,
    src.CargaBronze,
    src.Tier,
    src.RendaMensalAnterior,
    src.RendaMensalNova,
    src.RegraRenda,
    src.DataAtualizacaoOrigem,
    src.DataIngestao
);

-- Uma observação por usuário: a mais recente conhecida.
CREATE OR REPLACE VIEW gold.UsuarioAtual AS
WITH ranked AS (
    SELECT
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
        f.RegraRenda,
        ROW_NUMBER() OVER (
            PARTITION BY f.SkUsuario
            ORDER BY
                f.DataAtualizacaoOrigem DESC,
                f.DataIngestao DESC,
                f.SkObservacao DESC
        ) AS rn
    FROM gold.FatoUsuarioSnapshot AS f
    JOIN gold.DimUsuario AS d
        ON d.SkUsuario = f.SkUsuario
)
SELECT
    SkUsuario,
    IdUsuarioOrigem,
    NomeUsuario,
    SkObservacao,
    CargaBronze,
    Tier,
    RendaMensal,
    DataAtualizacaoOrigem,
    DataIngestao,
    RendaMensalAnterior,
    RendaMensalNova,
    RegraRenda
FROM ranked
WHERE rn = 1;

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

SELECT *
FROM gold.UsuarioAtual
ORDER BY IdUsuarioOrigem;

SELECT *
FROM gold.ResumoTierAtual
ORDER BY Tier;

SELECT *
FROM gold.ComparativoRendaAtual
ORDER BY IdUsuarioOrigem;
