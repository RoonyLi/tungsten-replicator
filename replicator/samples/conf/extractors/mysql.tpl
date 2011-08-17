replicator.extractor.dbms=com.continuent.tungsten.replicator.extractor.mysql.MySQLExtractor
replicator.extractor.dbms.binlog_dir=@{EXTRACTOR.REPL_MASTER_LOGDIR}
replicator.extractor.dbms.binlog_file_pattern=@{EXTRACTOR.REPL_MASTER_LOGPATTERN}
replicator.extractor.dbms.host=${replicator.global.extract.db.host}
replicator.extractor.dbms.port=${replicator.global.extract.db.port}
replicator.extractor.dbms.user=${replicator.global.extract.db.user}
replicator.extractor.dbms.password=${replicator.global.extract.db.password}
replicator.extractor.dbms.jdbcHeader=jdbc:mysql:thin://
replicator.extractor.dbms.parseStatements=true
replicator.extractor.dbms.usingBytesForString=true
replicator.extractor.dbms.transaction_frag_size=1000000
replicator.extractor.dbms.useRelayLogs=@{EXTRACTOR.REPL_DISABLE_RELAY_LOGS}
replicator.extractor.dbms.relayLogDir=@{SERVICE.REPL_RELAY_LOG_DIR}
replicator.extractor.dbms.relayLogWaitTimeout=0
replicator.extractor.dbms.relayLogRetention=10
replicator.extractor.dbms.serverId=@{APPLIER.REPL_MYSQL_SERVER_ID}