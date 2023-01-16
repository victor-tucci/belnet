#include <iostream>
#include <string_view>
#include <map>
#include <set>
#include "oxenmq/oxenmq.h"
#include "oxenmq/connections.h"
#include <chrono>
using namespace oxenmq;
int main()
{
    using LMQ_ptr = std::shared_ptr<oxenmq::OxenMQ>;
    LMQ_ptr m_LMQ = std::make_unique<oxenmq::OxenMQ>();
    m_LMQ->start();
    
    std::cout << "before connect remote \n";
      auto c = m_LMQ->connect_remote("tcp://194.5.152.31:1190",
      [](ConnectionID conn) { std::cout << "Connected \n";},
      [](ConnectionID conn, std::string_view f) { std::cout << "connect failed: \n";}
      );

    std::this_thread::sleep_for(2s);
      
    m_LMQ->request(c, "llarp.get_status", [](bool s, std::vector<std::string> d) {
            if (s && d.size() == 2)
            std::cout << "status: " << d[1] << "\n";
            else
            std::cout << "Timeout fetching status! : " << d[0] << "\n";
        });

    std::this_thread::sleep_for(20s);
}