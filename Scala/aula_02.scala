//> using dep org.postgresql:postgresql:42.7.13

import java.sql.{Connection, DriverManager}
import scala.util.Using
import scala.util.control.NonFatal

object Usuarios {

  // Configure essas variáveis no terminal antes de executar.
  private def abrirConexao(): Connection =
    DriverManager.getConnection(
      sys.env("DB_URL"),
      sys.env("DB_USER"),
      sys.env("DB_PASSWORD")
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

  def criarUsuario(
      nome: String,
      mensagem: String,
      tier: Int
  ): Long = {

    require(nome.trim.nonEmpty, "O nome não pode ficar vazio.")
    require(tier >= 1 && tier <= 3, "O tier deve ser 1, 2 ou 3.")

    transacao { conexao =>
      val sql = """
        INSERT INTO interacao_scala_postgre.Interacao (
          NomeUsuario, Mensagem, Tier
        )
        VALUES (?, ?, ?)
        RETURNING PkInteracao
      """

      Using.resource(conexao.prepareStatement(sql)) { stmt =>
        stmt.setString(1, nome.trim)
        stmt.setString(2, mensagem)
        stmt.setInt(3, tier)

        Using.resource(stmt.executeQuery()) { resultado =>
          if (!resultado.next())
            throw new IllegalStateException("O banco não retornou o ID.")

          resultado.getLong("PkInteracao")
        }
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
}

@main def testarUsuarios(): Unit = {
  val random = new scala.util.Random(42L)

  // Identifica os registros criados nesta execução.
  val lote = java.util.UUID.randomUUID().toString

  val quantidade = 100

  // Nomes inventados a partir da atmosfera de cada universo.
  // Cada grupo combina apenas seus próprios nomes e sobrenomes.
  val estilosDeNomes = Vector(
    // Skyrim: sonoridade nórdica e referências ao gelo e às montanhas.
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
    // Warhammer: sonoridade gótica, militar e sombria.
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
    // Lovecraft: nomes antigos e sobrenomes de atmosfera misteriosa.
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

  // Combinações fictícias, sem repetição de nome completo dentro do lote.
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

  // Cada elemento guarda: (ID retornado pelo banco, tier inicial).
  val usuarios = nomes.map { nome =>
    val tierInicial = random.nextInt(3) + 1

    val id = Usuarios.criarUsuario(
      nome = nome,
      mensagem = s"Dado sintetico | lote=$lote",
      tier = tierInicial
    )

    (id, tierInicial)
  }.toVector

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
