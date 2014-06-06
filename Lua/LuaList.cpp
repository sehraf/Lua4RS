#include <fstream>
#include <stdexcept>
#include <iostream>

#include "LuaList.h"

LuaList::LuaList()
{
    _luaList.clear();
}

LuaList::~LuaList()
{
    for(LuaContainerList::iterator it = _luaList.begin(); it != _luaList.end(); ++it)
        delete *it;

    _luaList.clear();
}

bool LuaList::itemAt(size_t index, LuaContainer*& container)
{
    // check if index is out of bound
    if(index >= _luaList.size())
        return false;

    container = _luaList.at(index);
    return true;
}

bool inline LuaList::itemByName(const QString &name, LuaContainer*& container)
{
    return itemByName(name.toStdString(), container);
}

bool LuaList::itemByName(const std::string& name, LuaContainer*& container)
{
    for(LuaContainerList::iterator it = _luaList.begin(); it != _luaList.end(); ++it)
        if((*it)->getLuaCode()->name() == name)
        {
            container = (*it);
            return true;
        }

    return false;
}

void LuaList::addItem(LuaContainer* lc)
{
    _luaList.push_back(lc);
}

size_t LuaList::size()
{
    return _luaList.size();
}

bool LuaList::load(const std::string& name, LuaContainer* container, const std::string& path)
{
    // load code
    {
        std::string fileName = path + name;

        if( !QFile::exists(fileName.c_str()))
        {
            std::cerr << "[Lua] can't find file " << fileName << std::endl;
            return false;
        }

        std::ifstream file;
        file.open(fileName.c_str(), std::ios::in);
        if(!file.good() || !file.is_open())
        {
            std::cerr << "[Lua] can't open file " << fileName << std::endl;
            return false;
        }

        std::string line, c;

        container->getLuaCode()->setName(name);

        ///TODO description
        container->getLuaCode()->setDesc("todo");

        // rest = code
        c = "";
        while(!file.eof())
        {
            std::getline(file, line);
            c += line + '\n';
        }
        container->getLuaCode()->setCode(c);

        file.close();
    }

    // load config
    ///TODO

    return true;
}

bool LuaList::loadAll(const std::string& path)
{
    std::cout << "[Lua] loading all script files from " << path << std::endl;

    // get everything with ".lua"
    /*
    QStringList nameFilter(QString::fromStdString("*.lua"));
    QDir directory(QString::fromStdString(path));
    QStringList files = directory.entryList(nameFilter);

    // drop folders
    for( QStringList::iterator it = files.begin(); it != files.end(); ++it)
        if( QFileInfo(*it).isDir())
            files.removeOne(*it);
    */


    QStringList files;
    QDirIterator dirIt(QString::fromStdString(path));
    while (dirIt.hasNext()) {
        dirIt.next();
        if (QFileInfo(dirIt.filePath()).isFile())
            if (QFileInfo(dirIt.filePath()).suffix() == "lua")
                files.append(dirIt.fileName());
    }


    // load lua files
    for( QStringList::iterator it = files.begin(); it != files.end(); ++it)
    {
        LuaContainer* c = new LuaContainer();
        std::cout << "[Lua] loading file " << it->toStdString() << " ..." << std::endl;
        if(load(it->toStdString(), c, path))
            _luaList.push_back(c);
        else
            std::cerr << "[Lua] can't load file " << it->toStdString() << std::endl;
    }
    if(_luaList.empty())
        return false;
    else
        return true;
}

bool LuaList::save(LuaContainer* container, const std::string& path)
{
    // safe code
    {
        std::string fileName = path + container->getLuaCode()->name();

        // check for .lua ending
        {
            QFile f(QString::fromStdString(fileName));
            QFileInfo fi(f);
            if(fi.suffix() != "lua")
                fileName += ".lua";
        }

        std::ofstream file;
        file.open(fileName.c_str(), std::ios::trunc);
        if(!file.is_open())
        {
            std::cerr << "[Lua] can't open file " << fileName << std::endl;
            return false;
        }

        ///TODO dstription

        // rest = code
        file << container->getLuaCode()->code();

        file.flush();
        file.close();
    }

    // save config
    ///TODO

    return true;
}

bool LuaList::saveAll(const std::string& path)
{
    std::cout << "[Lua] saving all script files" << std::endl;
    bool r = true;
    for(LuaContainerList::iterator it = _luaList.begin(); it != _luaList.end(); ++it)
        if(!save((*it), path))
        {
            std::cerr << "[Lua] failed to save lua script " << (*it)->getLuaCode()->name() << std::endl;
            r = false;
        }

    return r;
}

void LuaList::dump()
{
    std::cout << "[Lua] dumping LuaList: " << size() << " elements" << std::endl;
    uint counter = 0;
    for( LuaContainerList::iterator it = _luaList.begin(); it != _luaList.end(); ++it, counter++)
    {
        LuaContainer* c = *it;
        std::cout << " "<< counter << ": ";
        if( c == NULL)
            std::cout << "NULL" << std::endl;
        else
        {
            std::cout << "LuaCode: ";
            if(c->getLuaCode() == NULL)
                std::cout << "NULL" << std::endl;
            else
                std::cout << "Name: " << c->getLuaCode()->name() << std::endl;
        }
    }
}