/**
 * Tungsten Scale-Out Stack
 * Copyright (C) 2007-2010 Continuent Inc.
 * Contact: tungsten@continuent.org
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of version 2 of the GNU General Public License as
 * published by the Free Software Foundation.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA
 *
 * Initial developer(s): Teemu Ollakka
 * Contributor(s): Robert Hodges
 */

package com.continuent.tungsten.enterprise.replicator.thl;

import java.io.EOFException;
import java.io.IOException;
import java.nio.channels.SocketChannel;

import org.apache.log4j.Logger;

import com.continuent.tungsten.replicator.ReplicatorException;
import com.continuent.tungsten.replicator.plugin.PluginContext;
import com.continuent.tungsten.replicator.plugin.ReplicatorPlugin;
import com.continuent.tungsten.replicator.thl.ConnectorHandler;
import com.continuent.tungsten.replicator.thl.ProtocolHandshakeResponse;
import com.continuent.tungsten.replicator.thl.ProtocolHandshakeResponseValidator;
import com.continuent.tungsten.replicator.thl.ProtocolReplEventRequest;
import com.continuent.tungsten.replicator.thl.Server;
import com.continuent.tungsten.replicator.thl.THL;
import com.continuent.tungsten.replicator.thl.THLBinaryEvent;
import com.continuent.tungsten.replicator.thl.THLEvent;
import com.continuent.tungsten.replicator.thl.THLException;
import com.continuent.tungsten.replicator.util.AtomicCounter;

/**
 * This class defines a ConnectorHandler
 * 
 * @author <a href="mailto:teemu.ollakka@continuent.com">Teemu Ollakka</a>
 * @version 1.0
 */
public class ConnectorV2Handler extends ConnectorHandler implements ReplicatorPlugin, Runnable
{
    private Server           server    = null;
    private PluginContext    context   = null;
    private Thread           thd       = null;
    private SocketChannel    channel   = null;
    private AtomicCounter    seq       = null;
    private THL              thl       = null;
    private int              resetPeriod;
    private volatile boolean cancelled = false;
    private volatile boolean finished  = false;

    private static Logger    logger    = Logger
                                               .getLogger(ConnectorV2Handler.class);

    // Implements call-back to check log consistency between client and
    // master.
    class LogValidator implements ProtocolHandshakeResponseValidator
    {
        LogValidator()
        {
        }

        /**
         * Ensure that if the client has supplied log position information we
         * validate that the last epoch number and seqno match our log.
         * 
         * @param handshakeResponse Response from client
         * @throws THLException Thrown if logs appear to diverge
         */
        public void validateResponse(ProtocolHandshakeResponse handshakeResponse)
                throws InterruptedException, THLException
        {
            logger.info("New THL client connection from source ID: "
                    + handshakeResponse.getSourceId());

            long clientLastEpochNumber = handshakeResponse.getLastEpochNumber();
            long clientLastSeqno = handshakeResponse.getLastSeqno();
            if (clientLastEpochNumber < 0 || clientLastSeqno < 0)
            {
                logger
                        .info("Client log checking disabled; not checking for diverging histories");
            }
            else
            {
                THLEvent event = thl.find(clientLastSeqno, (short) 0);
                if (event == null)
                {
                    throw new THLException(
                            "Client log has higher sequence number than master: client source ID="
                                    + handshakeResponse.getSourceId()
                                    + " seqno=" + clientLastSeqno
                                    + " client epoch number="
                                    + clientLastEpochNumber);
                }
                else if (event.getEpochNumber() != clientLastEpochNumber)
                {
                    throw new THLException(
                            "Log epoch numbers do not match: client source ID="
                                    + handshakeResponse.getSourceId()
                                    + " seqno=" + clientLastSeqno
                                    + " server epoch number="
                                    + event.getEpochNumber()
                                    + " client epoch number="
                                    + clientLastEpochNumber);
                }
                else
                {
                    logger
                            .info("Log epoch numbers checked and match: client source ID="
                                    + handshakeResponse.getSourceId()
                                    + " seqno="
                                    + clientLastSeqno
                                    + " epoch number=" + clientLastEpochNumber);
                }
            }
        }
    }

    
    
    /**
     * Creates a new <code>ConnectorHandler</code> object
     * 
     */
    public ConnectorV2Handler()
    {
    }

    /**
     * Creates a new <code>ConnectorHandler</code> object
     */
    public ConnectorV2Handler(Server server, PluginContext context,
            SocketChannel channel, AtomicCounter seq, THL thl, int resetPeriod)
    {
        this.server = server;
        this.context = context;
        this.channel = channel;
        this.seq = seq;
        this.thl = thl;
        this.resetPeriod = resetPeriod;
    }

    /**
     * Returns true if this handler has terminated and may be discarded.
     */
    public boolean isFinished()
    {
        return finished;
    }

    /**
     * Implements the connector handler loop, which runs until we are
     * interrupted.
     */
    public void run()
    {
        ProtocolV2 protocol;
        try
        {
            protocol = new ProtocolV2(context, channel, resetPeriod, thl);
        }
        catch (IOException e)
        {
            logger.error("Unable to start connector handler", e);
            return;
        }
        try
        {
            long minSeqno, maxSeqno;
            maxSeqno = thl.getMaxStoredSeqno(false);
            minSeqno = thl.getMinStoredSeqno(false);
            LogValidator logValidator = new LogValidator();

            // TUC-2 Added log validator to check log for divergent
            // epoch numbers on last common sequence number.
            protocol.serverHandshake(logValidator, minSeqno, maxSeqno);

            // Name the thread so that developers can see which source ID we
            // are serving.
            Thread.currentThread().setName(
                    "ConnectorHandler: " + protocol.getClientSourceId());

            while (!cancelled)
            {
                ProtocolReplEventRequest request;

                request = protocol.waitReplEventRequest();

                long seqno = request.getSeqNo();
                logger.debug("Request " + seqno);
                long prefetchRange = request.getPrefetchRange();
                short fragno = 0;

                // for (long i = 0; i < prefetchRange; i++)
                // {
                long i = 0;
                while (i < prefetchRange)
                {
                    // Note: Waiting for a sequence number causes us to
                    // ignore clients going away until the next event or two
                    // is extracted.
                    if (logger.isDebugEnabled())
                        logger.debug("Waiting for sequence number: "
                                + (seqno + i));
                    seq.waitSeqnoGreaterEqual(seqno + i);

//                    THLEvent event = thl.find(seqno + i, fragno);
                    THLBinaryEvent event = thl.findBinaryEvent(seqno + i, fragno);

                    // Event can be null if it cannot be retrieved from database
                    if (event == null)
                    {
                        logger.warn("Requested event (#" + (seqno + i) + " / "
                                + fragno + ") not found in database");
//                        protocol
//                                .sendReplEvent(new ReplDBMSEvent(-1, null, null));
                        return;
                    }

//                    ReplEvent revent = event.getReplEvent();
//                    if (revent instanceof ReplDBMSEvent
//                            && ((ReplDBMSEvent) revent).getDBMSEvent() instanceof DBMSEmptyEvent)
//                    {
//                        logger.debug("Got an empty event");
//                        sendEvent(protocol, revent);
//                        i++;
//                        fragno = 0;
//                    }
//                    else
//                    {
//                        if (revent instanceof DBMSEmptyEvent)
//                        {
//                            ReplDBMSEvent replDBMSEvent = (ReplDBMSEvent) revent;
                            if (event.isLastFrag())
                            {
//                                if (replDBMSEvent instanceof ReplDBMSFilteredEvent)
//                                {
//                                    ReplDBMSFilteredEvent ev = (ReplDBMSFilteredEvent) replDBMSEvent;
//                                    i += 1 + ev.getSeqnoEnd() - ev.getSeqno();
//                                }
//                                else
//                                {
//                                    logger.debug("Last fragment of event "
//                                            + replDBMSEvent.getSeqno()
//                                            + " reached : "
//                                            + replDBMSEvent.getFragno());
                                    i++;
//                                }
                                fragno = 0;
                            }
                            else
                            {
//                                logger.debug("Not the last frag for event "
//                                        + replDBMSEvent.getSeqno() + "("
//                                        + replDBMSEvent.getFragno() + ")");
//                                if (replDBMSEvent instanceof ReplDBMSFilteredEvent)
//                                {
//                                    ReplDBMSFilteredEvent ev = (ReplDBMSFilteredEvent) replDBMSEvent;
//                                    fragno = (short) (ev.getFragnoEnd() + 1);
//                                }
//                                else
                                    fragno++;
                            }
//                        }
//                        else
//                        {
//                            logger.debug("Got " + revent.getClass());
//                            i++;
//                            fragno = 0;
//                        }
                        sendEvent(protocol, event);
                          
//                    }
                }
            }

        }
        catch (InterruptedException e)
        {
            if (cancelled)
                logger.info("Connector handler cancelled");
            else
                logger.error(
                        "Connector handler terminated by unexpected interrupt",
                        e);
        }
        catch (EOFException e)
        {
            // The EOF exception happens on a slave being promoted to master
            if (logger.isDebugEnabled())
                logger.info(
                        "Connector handler terminated by java.io.EOFException",
                        e);
            else
                logger
                        .info("Connector handler terminated by java.io.EOFException");
        }
        catch (IOException e)
        {
            // The IOException occurs normally when a client goes away.
            if (logger.isDebugEnabled())
                logger
                        .debug("Connector handler terminated by i/o exception",
                                e);
            else
                logger.info("Connector handler terminated by i/o exception");
        }
        catch (THLException e)
        {
            logger.error("Connector handler terminated by THL exception: "
                    + e.getMessage(), e);
        }
        catch (Throwable t)
        {
            logger.error(
                    "Connector handler terminated by unexpected exception", t);
        }
        finally
        {
            // Release storage.
//            thl.releaseStorageHandler();

            // Close TCP/IP.
            try
            {
                channel.close();
            }
            catch (Exception e)
            {
                logger.warn("Error on closing connection handle", e);
            }

            // Tell the server we are done.
            server.removeClient(this);

            // Make sure we can see that the connection ended.
            logger.info("Terminating THL client connection from source ID: "
                    + protocol.getClientSourceId());
        }
    }

    private void sendEvent(ProtocolV2 protocol, THLBinaryEvent event)
            throws IOException
    {
        protocol.sendDataAsByte(event.getData());
    }

    /**
     * Start the thread to serve thl changes to requesting slaves.
     */
    public void start()
    {
        thd = new Thread(this, "ConnectorHandler: initializing");
        thd.start();
    }

    /**
     * Stop the thread which is serving changes to requesting slaves.
     * 
     * @throws InterruptedException
     */
    public void stop() throws InterruptedException
    {
        if (finished)
            return;

        cancelled = true;

        // Stop handler thread.
        try
        {
            thd.interrupt();
            // Bound the wait to prevent hangs.
            thd.join(10000);
            thd = null;
        }
        catch (InterruptedException e)
        {
            // This is a possible JDK bug or at least inscrutable behavior.
            // First call to Thread.join() when deallocating threads seems
            // to trigger an immediate interrupt.
            logger.warn("Connector handler stop operation was interrupted");
            if (thd != null)
                thd.join();
        }
    }

    public void configure(PluginContext context) throws ReplicatorException,
            InterruptedException
    {
        this.context = context;
    }

    public void prepare(PluginContext context) throws ReplicatorException,
            InterruptedException
    {
        resetPeriod = thl.getResetPeriod();
    }

    public void release(PluginContext context) throws ReplicatorException,
            InterruptedException
    {
    }

    /**
     * Sets the server value.
     * 
     * @param server The server to set.
     */
    public void setServer(Server server)
    {
        this.server = server;
    }

    /**
     * Sets the channel value.
     * 
     * @param channel The channel to set.
     */
    public void setChannel(SocketChannel channel)
    {
        this.channel = channel;
    }

    /**
     * Sets the seq value.
     * 
     * @param seq The seq to set.
     */
    public void setSeq(AtomicCounter seq)
    {
        this.seq = seq;
    }

    /**
     * Sets the thl value.
     * 
     * @param thl The thl to set.
     */
    public void setThl(THL thl)
    {
        this.thl = thl;
    }

}