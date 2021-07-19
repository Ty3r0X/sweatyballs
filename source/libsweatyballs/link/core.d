module libsweatyballs.link.core;

import libsweatyballs.link.message.core;
import libsweatyballs.link.unit : LinkUnit;
import core.sync.mutex : Mutex;
import libsweatyballs.engine.core : Engine;
import core.thread : Thread;
import bmessage;
import std.socket;
import gogga;
import std.conv : to;
import google.protobuf;
import libsweatyballs.router.table : Route;
import libsweatyballs.zwitch.neighbor : Neighbor;

/**
* Link
*
* Description: Represents a "pipe" whereby different protocol messages can be transported over.
* Such protocol messages include data packet transport (receiving and sending) along with
* router advertisements messages
*
* This class handles the Message queues for sending and receiving messages (and partially decoding them)
*/
public final class Link : Thread
{
    /**
    * In and out queues
    */
    private LinkUnit[] inQueue;
    private LinkUnit[] outQueue;
    private Mutex inQueueLock;
    private Mutex outQueueLock;

    /**
    * Sockets
    */
    private Socket mcastSock;
    private Socket r2rSock;

    private string interfaceName;


    private Engine engine;

    this(string interfaceName, Engine engine)
    {
        /* Set the thread's worker function */
        super(&worker);

        this.interfaceName = interfaceName;
        this.engine = engine;

        /* Initialize locks */
        initMutexes();

        /* Setup networking */
        setupSockets();
    }

    public string getInterface()
    {
        return interfaceName;
    }

    /**
    * Initialize the queue mutexes
    */
    private void initMutexes()
    {
        inQueueLock = new Mutex();
        outQueueLock = new Mutex();
    }

    /**
    * Sets up sockets
    */
    private void setupSockets()
    {
        /* Setup the advertisement socket (bound to ff02::1%interface) port 6666 */
        mcastSock = new Socket(AddressFamily.INET6, SocketType.DGRAM, ProtocolType.UDP);
        mcastSock.bind(parseAddress("ff02::1%"~getInterface(), 6666));

        /* Setup the router-to-router socket (bound to ::) port 6667 */
        r2rSock = new Socket(AddressFamily.INET6, SocketType.DGRAM, ProtocolType.UDP);
        r2rSock.bind(parseAddress("::", 0));
    }

    /**
    * Returns the router-to-router port being used for this link
    */
    public ushort getR2RPort()
    {
        return to!(ushort)(r2rSock.localAddress.toPortString());
    }

    /**
    * Listens for advertisements
    *
    * TODO: We also must listen for traffic here though
    */
    private void worker()
    {
        while(true)
        {

            /**
            * MSG_PEEK, we don't want to dequeue this message yet but need to call receive
            * MSG_TRUNC, return the number of bytes of the datagram even when
            * bigger than passed in array
            */
            SocketFlags flags;
            flags |= MSG_TRUNC;
            flags |= MSG_PEEK;

            /* Receive buffer */
            byte[] data;
            Address address;

            /* Empty array won't work */
            data.length = 1;
            
            gprintln("Awaiting message...");
            long len = mcastSock.receiveFrom(data, flags, address);

            if(len <= 0)
            {
                /* TODO: Error handling */
            }
            else
            {
                /* Receive at the length found */
                data.length = len;
                mcastSock.receiveFrom(data, address);

                /* Decode the message */
                packet.Message message = decode(data);

                /* Couple Address-and-message */
                LinkUnit unit = new LinkUnit(address, message);

                /* Process message */
                process(unit); 
            }
            
        }
    }


    /**
    * Given Address we take the IP address (not source port of mcast packet)
    * and then also the `nieghborPort` and spit out a new Address
    */
    private static Address getNeighborIPAddress(Address sender, ushort neighborPort)
    {
        /* IPv6 reachable neighbor socket */
        Address neighborAddress = parseAddress(sender.toAddrString(), neighborPort);

        return neighborAddress;
    }

    /**
    * This will process the message
    *
    * Handles message type: SESSION, ADVERTISEMENT
    */
    private void process(LinkUnit unit)
    {
        /**
        * Message details
        *
        * 1. Public key
        * 2. Signature
        * 3. Neighbor port
        * 4. Message type
        * 5. Payload
        */
        packet.Message message = unit.getMessage();

        packet.MessageType mType = message.type;
        Address sender = unit.getSender();
        string identity = message.publicKey;
        ushort neighborPort = to!(ushort)(message.neighborPort);
        gprintln("Processing message from "~to!(string)(sender)~
                " of type "~to!(string)(mType));
        gprintln("Public key: "~identity);
        gprintln("Signature: Not yet implemented");
        gprintln("Neighbor Port: "~to!(string)(neighborPort));


        ubyte[] msgPayload = message.payload;

        /* Irrespective of the message type, add to NeighborDB */
        Address neighborAddress = getNeighborIPAddress(sender, neighborPort);
        Neighbor neighbor = new Neighbor(identity, neighborAddress);
        engine.getSwitch().addNeighbor(neighbor);

        /* Handle route advertisements */
        if(mType == packet.MessageType.ADVERTISEMENT)
        {
            advertisement.AdvertisementMessage advMsg = fromProtobuf!(advertisement.AdvertisementMessage)(msgPayload);

            /* Get the router-to-router port for router who sent the advertisement */
            ushort r2rPort = to!(ushort)(advMsg.r2rPort);

            /* Get the routes being advertised */
            RouteEntry[] routes = advMsg.routes;
            gprintln("Total of "~to!(string)(routes.length)~" received");

            /* TODO: Do router2router verification here */

            /* Add each route to the routing table */
            foreach(RouteEntry route; routes)
            {
                /* Create a new Address(routerAddr, r2rPort) */
                Address nexthop = parseAddress(sender.toAddrString(), r2rPort);
                uint metric = route.metric;

                /**
                * Create a new route with `nexthop` as the nexthop address
                * Also set its metric to whatever it is +64
                */
                Route newRoute = new Route(route.address, nexthop, identity, 100, metric+64);
                engine.getRouter().getTable().addRoute(newRoute);
            }
        }
        /* Handle session messages */
        else if(mType == packet.MessageType.SESSION)
        {

        }
        /* TODO: Does protobuf throw en error if so? */
        else
        {
            assert(false);
        }
    }

    public packet.Message decode(byte[] data)
    {
        ubyte[] dataIn = cast(ubyte[])data;
        packet.Message message = fromProtobuf!(packet.Message)(dataIn);
        return message;
    }

    private void enqueueIn(LinkUnit unit)
    {
        /* Add to the in-queue */
        inQueueLock.lock();
        inQueue ~= unit;
        inQueueLock.unlock();
    }

    public bool hasInQueue()
    {
        bool status;
        inQueueLock.lock();
        status = inQueue.length != 0;
        inQueueLock.unlock();
        return status;
    }

    public LinkUnit popInQueue()
    {
        LinkUnit message;

        /* TODO: Throw exception on `hasInQueue()` false */

        inQueueLock.lock();

        /* Pop the message */
        message = inQueue[0];

        if(inQueue.length == 1)
        {
            inQueue.length = 0;
        }
        else
        {
            inQueue = inQueue[1..inQueue.length];
        }

        inQueueLock.unlock();

        return message;
    }

    // public bool hasOutQueue()
    // {
    //     bool status;
    //     inQueueLock.lock();
    //     status = inQueue.length != 0;
    //     inQueueLock.unlock();
    //     return status;
    // }

    


    public void launch()
    {
        start();
    }



    /**
    * Blocks to receive one message from the incoming queue
    */
    public packet.Message receive()
    {
        /* TODO: Implement me */
        return null;
    }

    /**
    * Sends a message
    */
    public void send(packet.Message message, string recipient)
    {
        /* TODO: Implement me */
    }
}