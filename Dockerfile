ARG RUBY_VERSION
ARG DISTRO_NAME=bullseye

FROM ruby:$RUBY_VERSION-$DISTRO_NAME

RUN apt-get update -yqq && apt-get install -yqq --no-install-recommends \
  openjdk-11-jre-headless \
  raptor2-utils \
  && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /srv/ontoportal/ncbo_cron
RUN mkdir -p /srv/ontoportal/bundle
COPY Gemfile* *.gemspec /srv/ontoportal/ncbo_cron/

WORKDIR /srv/ontoportal/ncbo_cron

# set rubygem and bundler to the last version supported by ruby 2.7
# remove version after ruby v3 upgrade
RUN gem update --system '3.4.22'
RUN gem install bundler -v '2.4.22'
RUN gem update --system
RUN gem install bundler
ENV BUNDLE_PATH=/srv/ontoportal/bundle
RUN bundle install

COPY . /srv/ontoportal/ncbo_cron
RUN cp /srv/ontoportal/ncbo_cron/config/config.rb.sample /srv/ontoportal/ncbo_cron/config/config.rb

CMD ["/bin/bash"]
