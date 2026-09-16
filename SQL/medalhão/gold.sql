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

    RendaMensal numeric(14, 2)
        check (
            RendaMensal >= 0
            and RendaMensal < 'Infinity'::numeric
        ),

    DataAtualizacaoOrigem timestamp without time zone not null,
    DataIngestao timestamp without time zone not null,

    constraint FatoUsuarioSnapshotCargaUnica
        unique (SkUsuario, CargaBronze)
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
    RendaMensal,
    DataAtualizacaoOrigem,
    DataIngestao
)
SELECT
    s.SkObservacao,
    d.SkUsuario,
    s.CargaBronze,
    s.Tier,
    s.RendaMensal,
    s.DataAtualizacaoOrigem,
    b.DataIngestao
FROM silver.UsuarioSnapshot AS s
JOIN gold.DimUsuario AS d
    ON d.IdUsuarioOrigem = s.IdUsuarioOrigem
JOIN bronze.CargaUsuario AS b
    ON b.CargaBronze = s.CargaBronze
WHERE TRUE
ON CONFLICT (SkObservacao) DO NOTHING;

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
    f.RendaMensal,
    f.DataAtualizacaoOrigem,
    f.DataIngestao
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

    COUNT(RendaMensal) AS UsuariosComRendaInformada,

    ROUND(AVG(RendaMensal), 2) AS RendaMedia
FROM gold.UsuarioAtual
GROUP BY Tier;



SELECT
    (SELECT COUNT(*) FROM gold.DimUsuario) AS Usuarios,
    (SELECT COUNT(*) FROM gold.FatoUsuarioSnapshot) AS Observacoes,
    (SELECT COUNT(*) FROM gold.UsuarioAtual) AS UsuariosAtuais;

SELECT *
FROM gold.ResumoTierAtual
ORDER BY Tier;


