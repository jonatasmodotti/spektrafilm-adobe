#pragma once
#include "SPBasic.h"
#include <stdexcept>

namespace spektrafilm::adobe {
template<class T> class Suite {
  SPBasicSuite* basic_;
  const char* name_;
  int version_;
  const T* suite_ = nullptr;
public:
  Suite(SPBasicSuite* basic, const char* name, int version) : basic_(basic), name_(name), version_(version) {
    if (!basic_ || basic_->AcquireSuite(name_, version_, reinterpret_cast<const void**>(&suite_)) || !suite_)
      throw std::runtime_error("Required Adobe suite unavailable.");
  }
  ~Suite() { if (suite_) basic_->ReleaseSuite(name_, version_); }
  Suite(const Suite&) = delete;
  Suite& operator=(const Suite&) = delete;
  const T* operator->() const { return suite_; }
};
}
