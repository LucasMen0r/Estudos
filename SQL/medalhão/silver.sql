create schema if not exists silver;

create table if not exists silver.UsuarioSnapshot(
    SkObservacao integer generated always as identity primary key,
    CargaBronze UUID not NULL 
        references bronze.CargaUsuario(CargaBronze),
    IdUsuarioOrigem bigint not NULL
        check (IdUsuarioOrigem > 0),
    NomeUsuario text not NULL
        check (btrim(NomeUsuario) <> ''),
    tier smallint not NULL
        check (tier in (1, 2, 3)),
    
    RendaMensal numeric (14,2)
        check (
          RendaMensal >= 0 and RendaMensal < 'infinity'::numeric  
        ),
    mensagem text,
    DataInsercaoOrigem timestamp without time zone not NULL,
    DataAtualizacaoOrigem timestamp without time zone not NULL,
    DataTratamento timestamp without time zone default current_timestamp,

    constraint UsuarioSnapshotDataValida
        check (DataAtualizacaoOrigem >= DataInsercaoOrigem),

    constraint UsuarioSnapshotCargaUsuarioUnico
        unique(CargaBronze, IdUsuarioOrigem)
);
