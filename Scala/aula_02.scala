//> using dep org.postgresql:postgresql:42.7.13

import java.sql.{Connection, DriverManager}
import scala.util.Using
import scala.util.control.NonFatal

object Usuarios {

  final case class NovoUsuario(nome: String, mensagem: String, tier: Int)

  final case class ResultadoRenda(
      id: Long,
      nome: String,
      rendaBase: Int,
      tier: Int,
      alterado: Boolean
  )

  private def variavelObrigatoria(nome: String): String =
    sys.env.get(nome).filter(_.trim.nonEmpty).getOrElse {
      throw new IllegalStateException(
        s"Configure a variável de ambiente $nome antes de executar."
      )
    }

  // Estas variáveis apontam exclusivamente para o banco de negócio.
  private def abrirConexao(): Connection =
    DriverManager.getConnection(
      variavelObrigatoria("DB_URL"),
      variavelObrigatoria("DB_USER"),
      variavelObrigatoria("DB_PASSWORD")
    )

  // Cada operação recebe sua própria conexão e transação.
  private def transacao[A](operacao: Connection => A): A =
    Using.resource(abrirConexao()) { conexao =>
      conexao.setAutoCommit(false)

      try {
        val resultado = operacao(conexao)
        conexao.commit()
        resultado
      } catch {
        case NonFatal(erro) =>
          try conexao.rollback()
          catch {
            case NonFatal(erroRollback) =>
              erro.addSuppressed(erroRollback)
          }
          throw erro
      }
    }

  // Consulta o tier e bloqueia a linha até commit ou rollback.
  private def buscarTierComBloqueio(
      conexao: Connection,
      id: Long
  ): Option[Int] = {

    val sql = """
      SELECT Tier
      FROM interacao_scala_postgre.Interacao
      WHERE PkInteracao = ?
      FOR UPDATE
    """

    Using.resource(conexao.prepareStatement(sql)) { stmt =>
      stmt.setLong(1, id)

      Using.resource(stmt.executeQuery()) { resultado =>
        if (resultado.next()) Some(resultado.getInt("Tier"))
        else None
      }
    }
  }

  private val sqlCriarUsuario = """
    INSERT INTO interacao_scala_postgre.Interacao (
      NomeUsuario, Mensagem, Tier
    )
    VALUES (?, ?, ?)
    RETURNING PkInteracao
  """

  private def validar(usuario: NovoUsuario): Unit = {
    require(usuario.nome != null && usuario.nome.trim.nonEmpty,
      "O nome não pode ficar vazio.")
    require(usuario.mensagem != null, "A mensagem não pode ser nula.")
    require(usuario.tier >= 1 && usuario.tier <= 3,
      "O tier deve ser 1, 2 ou 3.")
  }

  private def inserirUsuario(
      stmt: java.sql.PreparedStatement,
      usuario: NovoUsuario
  ): Long = {
    stmt.setString(1, usuario.nome.trim)
    stmt.setString(2, usuario.mensagem)
    stmt.setInt(3, usuario.tier)

    Using.resource(stmt.executeQuery()) { resultado =>
      if (!resultado.next())
        throw new IllegalStateException("O banco não retornou o ID.")

      resultado.getLong("PkInteracao")
    }
  }

  def criarUsuario(nome: String, mensagem: String, tier: Int): Long = {
    val usuario = NovoUsuario(nome, mensagem, tier)
    validar(usuario)

    transacao { conexao =>
      Using.resource(conexao.prepareStatement(sqlCriarUsuario)) { stmt =>
        inserirUsuario(stmt, usuario)
      }
    }
  }

  // Insere o lote inteiro na mesma conexão e transação.
  // Em caso de erro, nenhuma linha do lote permanece gravada.
  def criarUsuarios(usuarios: Seq[NovoUsuario]): Vector[Long] = {
    val lote = usuarios.toVector
    lote.foreach(validar)

    transacao { conexao =>
      Using.resource(conexao.prepareStatement(sqlCriarUsuario)) { stmt =>
        lote.map(usuario => inserirUsuario(stmt, usuario))
      }
    }
  }

  // Retorna false se o usuário já estiver no tier solicitado.
  // Lança erro se o ID não existir.
  def atualizarTier(id: Long, novoTier: Int): Boolean = {
    require(
      novoTier >= 1 && novoTier <= 3,
      "O tier deve ser 1, 2 ou 3."
    )

    transacao { conexao =>
      val tierAnterior = buscarTierComBloqueio(conexao, id)
        .getOrElse {
          throw new NoSuchElementException(s"Usuário $id não encontrado.")
        }

      if (tierAnterior == novoTier) {
        false
      } else {
        val sqlHistorico = """
          INSERT INTO interacao_scala_postgre.InteracaoHistorico (
            FkInteracao, TierAnterior, TierNovo
          )
          VALUES (?, ?, ?)
        """

        Using.resource(conexao.prepareStatement(sqlHistorico)) { stmt =>
          stmt.setLong(1, id)
          stmt.setInt(2, tierAnterior)
          stmt.setInt(3, novoTier)
          stmt.executeUpdate()
        }

        val sqlAtualizacao = """
          UPDATE interacao_scala_postgre.Interacao
          SET Tier = ?,
              DataAtualizacao = CURRENT_TIMESTAMP
          WHERE PkInteracao = ?
        """

        Using.resource(conexao.prepareStatement(sqlAtualizacao)) { stmt =>
          stmt.setInt(1, novoTier)
          stmt.setLong(2, id)

          if (stmt.executeUpdate() != 1)
            throw new IllegalStateException("O cadastro não foi atualizado.")
        }

        true
      }
    }
  }

  // Exclusão definitiva: remove também todo o histórico vinculado.
  // Retorna false se o ID não existir.
  def removerUsuario(id: Long): Boolean =
    transacao { conexao =>
      buscarTierComBloqueio(conexao, id) match {
        case None =>
          false

        case Some(_) =>
          // Primeiro os registros que possuem a chave estrangeira.
          val sqlHistorico = """
            DELETE FROM interacao_scala_postgre.InteracaoHistorico
            WHERE FkInteracao = ?
          """

          Using.resource(conexao.prepareStatement(sqlHistorico)) { stmt =>
            stmt.setLong(1, id)
            stmt.executeUpdate()
          }

          // Depois o cadastro referenciado.
          val sqlUsuario = """
            DELETE FROM interacao_scala_postgre.Interacao
            WHERE PkInteracao = ?
          """

          Using.resource(conexao.prepareStatement(sqlUsuario)) { stmt =>
            stmt.setLong(1, id)

            if (stmt.executeUpdate() != 1)
              throw new IllegalStateException("O cadastro não foi removido.")
          }

          true
      }
    }

  // Busca os IDs reais, sem presumir que sejam consecutivos.
  def listarIdsUsuarios(): Vector[Long] =
    transacao { conexao =>
      val sql = """
        SELECT PkInteracao
        FROM interacao_scala_postgre.Interacao
        ORDER BY PkInteracao
      """

      Using.resource(conexao.prepareStatement(sql)) { stmt =>
        Using.resource(stmt.executeQuery()) { resultado =>
          val ids = Vector.newBuilder[Long]

          while (resultado.next()) {
            ids += resultado.getLong("PkInteracao")
          }

          ids.result()
        }
      }
    }

  def calcularTier(rendaMensal: Int): Int = {
    require(rendaMensal >= 0, "A renda não pode ser negativa.")

    if (rendaMensal < 2000) 1
    else if (rendaMensal < 7000) 2
    else 3
  }

  // Recebe a conexão da transação e uma linha já bloqueada.
  // Não abre outra conexão: renda, tier e histórico são uma única operação.
  private def gravarRendaETier(
      conexao: Connection,
      id: Long,
      rendaMensal: Int,
      tierAnterior: Int
  ): Boolean = {
    val novoTier = calcularTier(rendaMensal)

    val sql = """
      UPDATE interacao_scala_postgre.Interacao
      SET RendaMensal = ?,
          Tier = ?,
          DataAtualizacao = CURRENT_TIMESTAMP
      WHERE PkInteracao = ?
        AND (RendaMensal IS DISTINCT FROM ? OR Tier IS DISTINCT FROM ?)
    """

    val linhasAlteradas = Using.resource(conexao.prepareStatement(sql)) { stmt =>
      stmt.setInt(1, rendaMensal)
      stmt.setInt(2, novoTier)
      stmt.setLong(3, id)
      stmt.setInt(4, rendaMensal)
      stmt.setInt(5, novoTier)
      stmt.executeUpdate()
    }

    if (linhasAlteradas < 0 || linhasAlteradas > 1)
      throw new IllegalStateException("Quantidade inesperada de cadastros atualizados.")

    if (tierAnterior != novoTier) {
      if (linhasAlteradas != 1)
        throw new IllegalStateException("A alteração de tier não foi aplicada.")

      val sqlHistorico = """
        INSERT INTO interacao_scala_postgre.InteracaoHistorico (
          FkInteracao, TierAnterior, TierNovo
        )
        VALUES (?, ?, ?)
      """

      Using.resource(conexao.prepareStatement(sqlHistorico)) { stmt =>
        stmt.setLong(1, id)
        stmt.setInt(2, tierAnterior)
        stmt.setInt(3, novoTier)

        if (stmt.executeUpdate() != 1)
          throw new IllegalStateException("A mudança de tier não foi registrada.")
      }
    }

    linhasAlteradas == 1
  }

  // Entrada de renda pelo aplicativo: o tier é derivado automaticamente.
  // Sem mudanças de renda ou tier, retorna false e preserva a data anterior.
  def atualizarRenda(id: Long, rendaMensal: Int): Boolean = {
    require(id > 0, "O ID deve ser positivo.")
    require(rendaMensal >= 0, "A renda não pode ser negativa.")

    transacao { conexao =>
      val tierAnterior = buscarTierComBloqueio(conexao, id).getOrElse {
        throw new NoSuchElementException(s"Usuário $id não encontrado.")
      }

      gravarRendaETier(conexao, id, rendaMensal, tierAnterior)
    }
  }

  // Calcula a renda pelo nome e pelo ID reais do cadastro.
  // O nome é lido com bloqueio para evitar alterações concorrentes no cálculo.
  def aplicarRendaCalculada(id: Long): ResultadoRenda = {
    require(id > 0, "O ID deve ser positivo.")

    transacao { conexao =>
      val sql = """
        SELECT NomeUsuario, Tier
        FROM interacao_scala_postgre.Interacao
        WHERE PkInteracao = ?
        FOR UPDATE
      """

      val (nome, tierAnterior) =
        Using.resource(conexao.prepareStatement(sql)) { stmt =>
          stmt.setLong(1, id)

          Using.resource(stmt.executeQuery()) { resultado =>
            if (!resultado.next())
              throw new NoSuchElementException(s"Usuário $id não encontrado.")

            (resultado.getString("NomeUsuario"), resultado.getInt("Tier"))
          }
        }

      val renda = calcularRenda(nome, id)
      val alterado = gravarRendaETier(conexao, id, renda, tierAnterior)

      ResultadoRenda(id, nome, renda, calcularTier(renda), alterado)
    }
  }
}

// Renda-base: letras (sem espaços ou pontuação) x 15 x ID da origem.
// Os ajustes por ID pertencem à transformação da camada silver.
def calcularRenda(nome: String, id: Long): Int = {
  require(nome != null && nome.trim.nonEmpty, "O nome não pode ficar vazio.")
  require(id > 0, "O ID deve ser positivo.")

  val quantidadeLetras = nome.count(_.isLetter)

  val renda = BigInt(quantidadeLetras) * 15 * id

  require(
    renda <= BigInt(Int.MaxValue),
    "A renda ultrapassou o limite de INTEGER."
  )

  renda.toInt
}

// Exercício anterior preservado: cria cadastros e sorteia tiers.
// Não é chamado pelo @main atual e não aplica a nova regra de renda.
// Depois de usá-lo explicitamente, execute testarUsuarios para aplicar a regra.
def gerarUsuariosSinteticosLegado(): Unit = {
  val random = new scala.util.Random(42L)

  // Identifica os registros criados nesta execução.
  val lote = java.util.UUID.randomUUID().toString

  val quantidade = 200

  val estilosDeNomes = Vector(
    (
      Vector(
        "Arvild", "Brynja", "Eirvald", "Freydis", "Haldren",
        "Ingrun", "Jorvild", "Ragnhild", "Sigrund", "Torvann"
      ),
      Vector(
        "Passo da Geada", "Escudo de Inverno", "Filho da Neve",
        "Lobo do Norte", "Punho de Granito", "Voz da Montanha",
        "Lâmina de Gelo", "Olho da Aurora", "Coração de Pinheiro",
        "Guardião do Fiorde"
      )
    ),
    (
      Vector(
        "Severin", "Balthren", "Cassivar", "Dravorn", "Eisenrik",
        "Helkran", "Mordrath", "Octavren", "Valthera", "Vespera"
      ),
      Vector(
        "von Graufeld", "Ferro Sombrio", "Martelo de Cinzas",
        "Kaltenwacht", "Coroa de Aço", "Dornkreuz", "Vigília Rubra",
        "Punho de Obsidiana", "Lâmina do Ocaso", "von Nachtfels"
      )
    ),
    (
      Vector(
        "Abner", "Agatha", "Ambrose", "Beatrice", "Edmund",
        "Elias", "Ephraim", "Lenora", "Silas", "Tabitha"
      ),
      Vector(
        "Ashcombe", "Blackmere", "Coldwick", "Duskell", "Fenmarsh",
        "Grimhollow", "Morrowell", "Ravenshade", "Thornwick", "Wraithford"
      )
    )
  )
  val combinacoes = (for {
    (primeirosNomes, sobrenomes) <- estilosDeNomes
    primeiroNome <- primeirosNomes
    sobrenome <- sobrenomes
  } yield s"$primeiroNome $sobrenome").distinct

  require(
    quantidade >= 0 && quantidade <= combinacoes.size,
    s"A quantidade deve estar entre 0 e ${combinacoes.size}."
  )

  // Semente separada para preservar o sorteio dos tiers e das atualizações.
  val nomes = new scala.util.Random(42L).shuffle(combinacoes).take(quantidade)

  val novosUsuarios = nomes.map { nome =>
    Usuarios.NovoUsuario(
      nome = nome,
      mensagem = s"Dado sintético | lote=$lote",
      tier = random.nextInt(3) + 1
    )
  }.toVector

  // Cada elemento guarda: (ID retornado pelo banco, tier inicial).
  val ids = Usuarios.criarUsuarios(novosUsuarios)
  val usuarios = ids.zip(novosUsuarios.map(_.tier))

  println(s"Lote: $lote")
  println(s"Usuários criados: ${usuarios.size}")

  // Mostra a distribuição inicial dos usuários deste lote.
  for (tier <- 1 to 3) {
    val total = usuarios.count { case (_, tierInicial) =>
      tierInicial == tier
    }

    println(s"Tier $tier na criação: $total usuários")
  }

  // Seleciona 30 usuários diferentes, aleatoriamente.
  val selecionados = random.shuffle(usuarios).take(30)

  // Guarda o ID e o novo tier após cada atualização.
  val atualizados = selecionados.map { case (id, tierAnterior) =>

    // Seleciona um dos outros dois tiers.
    val alternativas = Vector(1, 2, 3).filter(_ != tierAnterior)
    val novoTier = alternativas(random.nextInt(alternativas.size))

    val alterado = Usuarios.atualizarTier(id, novoTier)

    require(alterado, s"A mudança do usuário $id não foi realizada.")

    println(s"Usuário $id: tier $tierAnterior -> $novoTier")

    (id, novoTier)
  }

  println(s"Mudanças realizadas: ${atualizados.size}")

  // Repete o tier já aplicado a 10 usuários.
  val semAlteracao = atualizados.take(10).count { case (id, tierAtual) =>
    val alterado = Usuarios.atualizarTier(id, tierAtual)
    !alterado
  }

  println(s"Atualizações repetidas sem mudança: $semAlteracao")
}

// Requer a coluna RendaMensal NUMERIC com CHECK (RendaMensal >= 0) na origem.
// Atualiza somente cadastros existentes. Cada usuário tem sua própria transação.
// Exporte um novo snapshot após concluir para alimentar bronze, silver e gold.
@main def testarUsuarios(): Unit = {
  val ids = Usuarios.listarIdsUsuarios()

  if (ids.isEmpty) {
    println("Nenhum usuário encontrado. Nenhuma alteração realizada.")
  } else {
    val resultados = ids.map { id =>
      val resultado = Usuarios.aplicarRendaCalculada(id)

      println(
        s"${resultado.nome} (ID ${resultado.id}): " +
        s"renda-base ${resultado.rendaBase} septims; tier ${resultado.tier}; " +
        s"alterado=${resultado.alterado}"
      )

      resultado
    }

    val alterados = resultados.count(_.alterado)
    println(s"Usuários encontrados: ${resultados.size}")
    println(s"Cadastros alterados: $alterados")
    println(s"Cadastros já consistentes: ${resultados.size - alterados}")

    for (tier <- 1 to 3) {
      val quantidade = resultados.count(_.tier == tier)
      println(s"Tier $tier: $quantidade usuários")
    }
  }
}
